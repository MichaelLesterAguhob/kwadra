import type { Express, Request, Response } from "express";
import type pg from "pg";
import { randomBytes, randomUUID, createHash } from "node:crypto";
import { z } from "zod";
import { rateLimit } from "express-rate-limit";
import { authenticate, hashPassword, hashToken } from "./auth.js";
import { transaction, type Db } from "./db.js";
import { canonical } from "./operations.js";
import { requireCondition } from "./errors.js";
import { config } from "./config.js";
import { queueMail } from "./mail.js";
import {
  publicJoins,
  eligible,
  publicListing,
  createInquiry,
  conversationView,
  appendSeekerMessage,
  actOnSeekerViewing,
  reportListing,
} from "./marketplace.js";

const id = (req: Request) => z.uuid().parse(req.params.id);
async function ownInquiry(db: Db, userId: string, inquiryId: string) {
  const row = (
    await db.query(
      "SELECT i.*,l.title FROM inquiries i JOIN listings l ON l.id=i.listing_id WHERE i.id=$1 AND i.seeker_id=$2",
      [inquiryId, userId],
    )
  ).rows[0];
  requireCondition(row, "Conversation not found.", 404);
  return row;
}
async function accountWrite(
  pool: pg.Pool,
  req: Request,
  res: Response,
  fn: (db: Db, userId: string) => Promise<unknown>,
) {
  const account = req.account!,
    key = z
      .string()
      .min(8)
      .max(120)
      .regex(/^[a-zA-Z0-9-]+$/)
      .parse(req.header("Idempotency-Key"));
  const hash = createHash("sha256")
    .update(canonical({ method: req.method, path: req.path, body: req.body }))
    .digest("hex");
  const result = await transaction(pool, async (db) => {
    await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
      "account:" + account.userId,
    ]);
    const valid = await db.query(
      "SELECT s.token_hash FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=$1 AND s.user_id=$2 AND s.expires_at>now() AND NOT u.disabled AND u.email_verified_at IS NOT NULL FOR SHARE OF s,u",
      [account.tokenHash, account.userId],
    );
    requireCondition(valid.rowCount, "Sign in again to continue.", 401);
    const previous = (
      await db.query(
        "SELECT * FROM account_idempotency_keys WHERE user_id=$1 AND key=$2",
        [account.userId, key],
      )
    ).rows[0];
    if (previous) {
      requireCondition(
        previous.payload_hash === hash,
        "This retry key belongs to a different request.",
        409,
      );
      return previous.response;
    }
    // Personal marketplace data survives later removal from a staff workspace.
    await db.query(
      "UPDATE users SET marketplace_account=true WHERE id=$1 AND NOT marketplace_account",
      [account.userId],
    );
    const response = { data: await fn(db, account.userId) };
    await db.query(
      "INSERT INTO account_idempotency_keys(user_id,key,payload_hash,response) VALUES($1,$2,$3,$4)",
      [account.userId, key, hash, JSON.stringify(response)],
    );
    return response;
  });
  res.json(result);
}
export function mobileMarketplaceRoutes(
  app: Express,
  pool: pg.Pool,
  testing = false,
) {
  if (!testing)
    app.use(
      "/api/v1/auth/register-seeker",
      rateLimit({
        windowMs: 15 * 60_000,
        limit: 10,
        standardHeaders: "draft-8",
        legacyHeaders: false,
      }),
    );
  app.post("/api/v1/auth/register-seeker", async (req, res) => {
    requireCondition(
      !config.production || !!process.env.SMTP_HOST,
      "Account signup needs the email service to be configured.",
      503,
    );
    const b = z
      .object({
        name: z.string().trim().min(1).max(120),
        email: z.email().max(254),
        password: z.string().min(12).max(256),
      })
      .strict()
      .parse(req.body);
    const password = await hashPassword(b.password),
      userId = randomUUID(),
      token = randomBytes(32).toString("hex");
    await transaction(pool, async (db) => {
      await db.query(
        "INSERT INTO users(id,name,email,password_hash,marketplace_account) VALUES($1,$2,$3,$4,true)",
        [userId, b.name, b.email.toLowerCase(), password],
      );
      await db.query(
        "INSERT INTO identity_tokens(token_hash,user_id,purpose,expires_at) VALUES($1,$2,'verify_email',now()+interval '24 hours')",
        [hashToken(token), userId],
      );
      await queueMail(
        db,
        null,
        userId,
        b.email.toLowerCase(),
        "Verify your Kwadra email",
        `Your verification code: ${token}\nValid for 24 hours.`,
        randomUUID(),
      );
    });
    res.status(201).json({
      message: "Account created. Verify your email before signing in.",
    });
  });
  app.use("/api/v1/marketplace", authenticate(pool, true));
  if (!testing)
    app.use("/api/v1/marketplace", (req, res, next) => {
      if (["GET", "HEAD", "OPTIONS"].includes(req.method)) return next();
      return marketplaceWrites(req, res, next);
    });
  const read = (
    req: Request,
    res: Response,
    fn: (db: Db, userId: string) => Promise<unknown>,
  ) =>
    transaction(pool, (db) => fn(db, req.account!.userId)).then((data) =>
      res.json(data),
    );
  app.get("/api/v1/marketplace/saved", async (req, res) =>
    read(req, res, async (db, userId) => {
      const ids = (
        await db.query(
          `SELECT l.id ${publicJoins} JOIN saved_listings s ON s.listing_id=l.id WHERE s.user_id=$1 AND ${eligible} ORDER BY s.created_at DESC`,
          [userId],
        )
      ).rows;
      const data = [];
      for (const row of ids) data.push(await publicListing(db, row.id));
      const total = (
        await db.query(
          "SELECT count(*)::int AS n FROM saved_listings WHERE user_id=$1",
          [userId],
        )
      ).rows[0].n;
      return { data, unavailableCount: total - data.length };
    }),
  );
  app.put("/api/v1/marketplace/saved/:id", async (req, res) =>
    accountWrite(pool, req, res, async (db, userId) => {
      const b = z.object({ saved: z.boolean() }).strict().parse(req.body),
        listingId = id(req);
      if (b.saved) {
        await publicListing(db, listingId);
        await db.query(
          "INSERT INTO saved_listings(user_id,listing_id) VALUES($1,$2) ON CONFLICT DO NOTHING",
          [userId, listingId],
        );
      } else
        await db.query(
          "DELETE FROM saved_listings WHERE user_id=$1 AND listing_id=$2",
          [userId, listingId],
        );
      return { id: listingId, saved: b.saved };
    }),
  );
  app.get("/api/v1/marketplace/inquiries", async (req, res) =>
    read(req, res, async (db, userId) => ({
      data: (
        await db.query(
          `SELECT i.id,i.listing_id AS "listingId",l.title,l.location_label AS "locationLabel",i.status,i.created_at AS created,
 (SELECT body FROM inquiry_messages m WHERE m.inquiry_id=i.id ORDER BY m.created_at DESC,m.id DESC LIMIT 1) AS "lastMessage"
 FROM inquiries i JOIN listings l ON l.id=i.listing_id WHERE i.seeker_id=$1 ORDER BY (SELECT max(created_at) FROM inquiry_messages WHERE inquiry_id=i.id) DESC,i.id DESC`,
          [userId],
        )
      ).rows,
    })),
  );
  app.post("/api/v1/marketplace/listings/:id/inquiries", async (req, res) =>
    accountWrite(pool, req, res, async (db, userId) => {
      const b = z
        .object({
          message: z.string().trim().min(10).max(3000),
          phone: z.string().max(60).default(""),
          viewingAt: z.string().optional(),
        })
        .strict()
        .parse(req.body);
      const user = (
        await db.query("SELECT name,email FROM users WHERE id=$1", [userId])
      ).rows[0];
      return createInquiry(
        db,
        id(req),
        { ...b, name: user.name, email: user.email },
        userId,
      );
    }),
  );
  app.get("/api/v1/marketplace/inquiries/:id", async (req, res) =>
    read(req, res, async (db, userId) =>
      conversationView(db, await ownInquiry(db, userId, id(req))),
    ),
  );
  app.post("/api/v1/marketplace/inquiries/:id/messages", async (req, res) =>
    accountWrite(pool, req, res, async (db, userId) =>
      appendSeekerMessage(db, await ownInquiry(db, userId, id(req)), req.body),
    ),
  );
  app.post("/api/v1/marketplace/inquiries/:id/viewings", async (req, res) =>
    accountWrite(pool, req, res, async (db, userId) =>
      actOnSeekerViewing(db, await ownInquiry(db, userId, id(req)), req.body),
    ),
  );
  app.post("/api/v1/marketplace/listings/:id/report", async (req, res) =>
    accountWrite(pool, req, res, async (db, userId) => {
      const b = z
          .object({ reason: z.string().trim().min(10).max(2000) })
          .strict()
          .parse(req.body),
        user = (await db.query("SELECT email FROM users WHERE id=$1", [userId]))
          .rows[0];
      return reportListing(db, id(req), { ...b, email: user.email });
    }),
  );
  app.post("/api/v1/marketplace/organization", async (req, res) =>
    accountWrite(pool, req, res, async (db, userId) => {
      const b = z
        .object({ name: z.string().trim().min(1).max(160) })
        .strict()
        .parse(req.body);
      requireCondition(
        !(
          await db.query(
            "SELECT 1 FROM memberships WHERE user_id=$1 AND role IN ('owner','admin') AND active",
            [userId],
          )
        ).rowCount,
        "This account already manages a workspace.",
        409,
      );
      const orgId = randomUUID();
      await db.query("INSERT INTO organizations(id,name) VALUES($1,$2)", [
        orgId,
        b.name,
      ]);
      await db.query(
        "INSERT INTO memberships(organization_id,user_id,role,all_properties) VALUES($1,$2,'owner',true)",
        [orgId, userId],
      );
      return { organizationId: orgId };
    }),
  );
}
const marketplaceWrites = rateLimit({
  windowMs: 15 * 60_000,
  limit: 80,
  standardHeaders: "draft-8",
  legacyHeaders: false,
});
