import express from "express";
import helmet from "helmet";
import { rateLimit } from "express-rate-limit";
import swaggerUi from "swagger-ui-express";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import path from "node:path";
import { z } from "zod";
import type pg from "pg";
import { config, root } from "./config.js";
import { authenticate, authRoutes } from "./auth.js";
import { ApiError, errorHandler } from "./errors.js";
import { workspace } from "./snapshot.js";
import {
  write,
  saveProperty,
  saveUnit,
  saveTenant,
  createLease,
  endLease,
  generateInvoices,
  saveTicket,
  updateProfile,
} from "./operations.js";
import { openapi } from "./openapi.js";
import { publicPhaseRoutes, protectedPhaseRoutes } from "./phase-routes.js";
import { marketplaceSite } from "./marketplace-site.js";
import { mobileMarketplaceRoutes } from "./mobile-marketplace.js";
import { accountRoutes, type GoogleVerifier } from "./google-auth.js";
import { personalNotificationRoutes } from "./notifications.js";

export function createApp(
  pool: pg.Pool,
  options: { testing?: boolean; googleVerifier?: GoogleVerifier } = {},
) {
  const app = express();
  app.disable("x-powered-by");
  if (config.production) app.set("trust proxy", 1);
  // Flutter's generated web bootstrap and Swagger need their own CSP policy;
  // the authenticated API never serves HTML. Set CSP at the deployment proxy.
  app.use(
    helmet({
      crossOriginOpenerPolicy: { policy: "same-origin-allow-popups" },
      contentSecurityPolicy: false,
      crossOriginResourcePolicy: { policy: "cross-origin" },
    }),
  );
  app.use((req, res, next) => {
    res.locals.requestId = randomUUID();
    res.setHeader("X-Request-Id", res.locals.requestId);
    if (req.path.startsWith("/api/"))
      res.setHeader("Cache-Control", "no-store");
    const origin = req.header("Origin");
    if (origin) {
      const own = `${req.protocol}://${req.get("host")}`;
      if (origin !== own && !config.origins.includes(origin))
        throw new ApiError(
          403,
          "This browser origin is not allowed. Configure CORS_ORIGINS.",
          "ORIGIN_DENIED",
        );
      res.setHeader("Access-Control-Allow-Origin", origin);
      res.vary("Origin");
      res.setHeader("Access-Control-Allow-Credentials", "true");
      res.setHeader(
        "Access-Control-Allow-Headers",
        "Content-Type, Authorization, X-Organization-Id, X-CSRF-Token, Idempotency-Key, X-Inquiry-Token",
      );
      res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS");
    }
    if (req.method === "OPTIONS") {
      res.sendStatus(204);
      return;
    }
    next();
  });
  if (!options.testing)
    app.use(
      "/api",
      rateLimit({
        windowMs: 60_000,
        limit: 600,
        standardHeaders: "draft-8",
        legacyHeaders: false,
        message: {
          error: {
            code: "RATE_LIMITED",
            message: "Too many requests. Try again shortly.",
          },
        },
      }),
    );
  app.use(express.json({ limit: "3mb" }));
  app.get("/health", (_req, res) => {
    res.json({ status: "ok", service: "kwadra-api", version: "0.6.0" });
  });
  app.get("/ready", async (_req, res) => {
    try {
      const result = await pool.query(
        "SELECT count(*)::int AS n FROM schema_migrations",
      );
      if (result.rows[0].n < 5) throw new Error("Migrations pending");
    } catch {
      throw new ApiError(
        503,
        "Database unavailable or migrations are pending.",
        "NOT_READY",
      );
    }
    res.json({ status: "ready", database: "postgresql" });
  });
  app.get("/openapi.json", (_req, res) => res.json(openapi));
  const explorerSpec = structuredClone(openapi);
  // Explorer convenience only: the interceptor supplies these headers after
  // login. The downloadable contract keeps the API's required headers intact.
  for (const item of Object.values(explorerSpec.paths) as any[]) {
    for (const operation of Object.values(item) as any[]) {
      for (const parameter of operation.parameters ?? [])
        if (parameter.in === "header") parameter.required = false;
    }
  }
  app.use(
    "/docs",
    swaggerUi.serve,
    swaggerUi.setup(explorerSpec, {
      swaggerOptions: {
        persistAuthorization: false,
        withCredentials: true,
        requestInterceptor: function (req: any) {
          const state = globalThis as any;
          if (state.kwadraOrg && !req.headers["X-Organization-Id"])
            req.headers["X-Organization-Id"] = state.kwadraOrg;
          if (state.kwadraCsrf) req.headers["X-CSRF-Token"] = state.kwadraCsrf;
          if (
            ["POST", "PUT"].includes(req.method.toUpperCase()) &&
            !req.url.endsWith("/auth/login") &&
            !req.url.endsWith("/auth/register")
          ) {
            if (!req.headers["Idempotency-Key"])
              req.headers["Idempotency-Key"] = crypto.randomUUID();
          }
          req.credentials = "include";
          return req;
        },
        responseInterceptor: function (res: any) {
          if (res.url?.endsWith("/auth/login") && res.status === 200) {
            const body = res.obj ?? JSON.parse(res.text);
            const state = globalThis as any;
            state.kwadraOrg = body.organizations[0]?.id;
            state.kwadraCsrf = body.csrfToken;
          }
          return res;
        },
      },
    }),
  );
  const auth = authRoutes(pool);
  accountRoutes(app, pool, options);
  publicPhaseRoutes(app, pool, options.testing);
  if (!options.testing)
    app.use(
      "/api/v1/auth/login",
      rateLimit({
        windowMs: 15 * 60_000,
        limit: 30,
        standardHeaders: "draft-8",
        legacyHeaders: false,
        message: {
          error: {
            code: "RATE_LIMITED",
            message: "Too many sign-in attempts. Wait 15 minutes.",
          },
        },
      }),
    );
  app.post("/api/v1/auth/login", auth.login);
  // Open local registration is intentionally unavailable in production until
  // verified email and abuse controls are implemented.
  if (!config.production) app.post("/api/v1/auth/register", auth.register);
  mobileMarketplaceRoutes(app, pool, options.testing);
  personalNotificationRoutes(app, pool);
  app.get("/api/v1/auth/me", authenticate(pool, true), auth.me);
  app.post("/api/v1/auth/logout", authenticate(pool, true), auth.logout);
  app.use("/api/v1", authenticate(pool));
  protectedPhaseRoutes(app, pool);
  app.get("/api/v1/workspace", async (req, res) =>
    res.json(await workspace(pool, req.auth!)),
  );

  const collections = [
    "properties",
    "units",
    "tenants",
    "leases",
    "invoices",
    "tickets",
    "activity",
  ] as const;
  for (const resource of collections) {
    app.get(`/api/v1/${resource}`, async (req, res) => {
      const query = z
        .object({
          page: z.coerce.number().int().min(1).default(1),
          pageSize: z.coerce.number().int().min(1).max(100).default(25),
          q: z.string().max(160).optional(),
          propertyId: z.uuid().optional(),
          unitId: z.uuid().optional(),
          status: z.string().max(40).optional(),
        })
        .strict()
        .parse(req.query);
      const snapshot = await workspace(pool, req.auth!);
      let records = (
        resource === "activity" ? snapshot.activities : snapshot[resource]
      ) as Record<string, any>[];
      if (query.q) {
        const q = query.q.toLowerCase();
        records = records.filter((r) =>
          [r.name, r.code, r.title, r.number, r.email, r.phone].some(
            (v) => typeof v === "string" && v.toLowerCase().includes(q),
          ),
        );
      }
      if (query.propertyId) {
        const ids = snapshot.units
          .filter((u) => u.propertyId === query.propertyId)
          .map((u) => u.id);
        records = records.filter(
          (r) => r.propertyId === query.propertyId || ids.includes(r.unitId),
        );
      }
      if (query.unitId)
        records = records.filter((r) => r.unitId === query.unitId);
      if (query.status)
        records = records.filter((r) => r.status === query.status);
      const offset = (query.page - 1) * query.pageSize;
      res.json({
        data: records.slice(offset, offset + query.pageSize),
        page: query.page,
        pageSize: query.pageSize,
        total: records.length,
      });
    });
    if (resource !== "activity")
      app.get(`/api/v1/${resource}/:id`, async (req, res) => {
        const id = z.uuid().parse(req.params.id),
          snapshot = await workspace(pool, req.auth!);
        const row = snapshot[resource].find((r) => r.id === id);
        if (!row)
          throw new ApiError(
            404,
            "Record not found or unavailable.",
            "NOT_FOUND",
          );
        res.json({ data: row });
      });
  }
  for (const [resource, save] of [
    ["properties", saveProperty],
    ["units", saveUnit],
    ["tenants", saveTenant],
    ["tickets", saveTicket],
  ] as const) {
    app.post(`/api/v1/${resource}`, async (req, res) =>
      write(pool, req, res, `create-${resource}`, (db, ctx) =>
        save(db, ctx, req.body),
      ),
    );
    app.put(`/api/v1/${resource}/:id`, async (req, res) => {
      const id = z.uuid().parse(req.params.id);
      await write(pool, req, res, `update-${resource}`, (db, ctx) =>
        save(db, ctx, req.body, id),
      );
    });
  }
  app.post("/api/v1/leases", async (req, res) =>
    write(pool, req, res, "create-lease", (db, ctx) =>
      createLease(db, ctx, req.body),
    ),
  );
  app.post("/api/v1/leases/:id/end", async (req, res) => {
    const id = z.uuid().parse(req.params.id);
    await write(pool, req, res, "end-lease", (db, ctx) =>
      endLease(db, ctx, id, req.body),
    );
  });
  app.post("/api/v1/invoices/generate", async (req, res) =>
    write(pool, req, res, "generate-invoices", (db, ctx) =>
      generateInvoices(db, ctx, req.body),
    ),
  );
  app.put("/api/v1/profile", async (req, res) =>
    write(pool, req, res, "update-profile", (db, ctx) =>
      updateProfile(db, ctx, req.body),
    ),
  );
  app.use("/api", (_req, _res) => {
    throw new ApiError(404, "API endpoint not found.", "NOT_FOUND");
  });
  marketplaceSite(app, pool);
  app.use((_req, res, next) => {
    res.setHeader("X-Robots-Tag", "noindex, nofollow");
    next();
  });
  const web = path.join(root, "../apps/management/build/web");
  if (existsSync(path.join(web, "index.html"))) {
    app.use(
      express.static(web, {
        index: "index.html",
        setHeaders: (res, file) => {
          if (
            file.endsWith(".html") ||
            file.endsWith("flutter_bootstrap.js") ||
            file.endsWith("version.json")
          )
            res.setHeader("Cache-Control", "no-store");
        },
      }),
    );
    app.get("/{*path}", (_req, res) =>
      res.sendFile(path.join(web, "index.html")),
    );
  }
  app.use(errorHandler);
  return app;
}
