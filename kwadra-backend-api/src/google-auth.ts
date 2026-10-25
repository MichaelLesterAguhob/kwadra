import { OAuth2Client } from "google-auth-library";
import { randomBytes, randomUUID } from "node:crypto";
import type { Express } from "express";
import type pg from "pg";
import { z } from "zod";
import { rateLimit } from "express-rate-limit";
import { authenticate, verifyPassword } from "./auth.js";
import { transaction } from "./db.js";
import { ApiError, requireCondition } from "./errors.js";
import { establishSession, rotateSession } from "./sessions.js";
import { hashToken } from "./auth.js";
import { queueMail } from "./mail.js";
import { config } from "./config.js";

export type GoogleIdentity = {
  sub: string;
  email: string;
  email_verified: boolean;
  name?: string;
  hd?: string;
};
export type GoogleVerifier = (token: string) => Promise<GoogleIdentity>;
const google = new OAuth2Client();
export async function verifyGoogle(token: string): Promise<GoogleIdentity> {
  const audience = process.env.GOOGLE_WEB_CLIENT_ID;
  if (!audience)
    throw new ApiError(
      503,
      "Google sign-in is not configured.",
      "GOOGLE_UNAVAILABLE",
    );
  try {
    const ticket = await google.verifyIdToken({ idToken: token, audience });
    const p = ticket.getPayload();
    if (!p?.sub || !p.email || !p.email_verified)
      throw new Error("Invalid identity");
    return {
      sub: p.sub,
      email: p.email,
      email_verified: p.email_verified,
      name: p.name,
      hd: p.hd,
    };
  } catch {
    throw new ApiError(
      401,
      "Google could not verify this sign-in. Try again.",
      "GOOGLE_INVALID",
    );
  }
}
export function accountRoutes(
  app: Express,
  pool: pg.Pool,
  options: { testing?: boolean; googleVerifier?: GoogleVerifier } = {},
) {
  const verify = options.googleVerifier ?? verifyGoogle;
  app.get("/api/v1/auth/providers", (_req, res) =>
    res.json({
      google: {
        enabled: !!process.env.GOOGLE_WEB_CLIENT_ID,
        webClientId: process.env.GOOGLE_WEB_CLIENT_ID ?? null,
        iosClientId: process.env.GOOGLE_IOS_CLIENT_ID ?? null,
      },
    }),
  );
  if (!options.testing)
    app.use(
      ["/api/v1/auth/google", "/api/v1/auth/refresh"],
      rateLimit({
        windowMs: 15 * 60000,
        limit: 60,
        standardHeaders: "draft-8",
        legacyHeaders: false,
      }),
    );
  app.post("/api/v1/auth/refresh", async (req, res) => {
    const b = z
      .object({ refreshToken: z.string().regex(/^[a-f0-9]{64}$/) })
      .strict()
      .parse(req.body);
    await rotateSession(pool, res, b.refreshToken);
  });
  const tokenInput = z
    .object({
      idToken: z.string().min(10).max(12000),
      client: z.enum(["web", "native"]).default("web"),
      mfaCode: z
        .string()
        .regex(/^\d{6}$/)
        .optional(),
    })
    .strict();
  app.post("/api/v1/auth/google", async (req, res) => {
    const b = tokenInput.parse(req.body),
      p = await verify(b.idToken);
    requireCondition(
      p.email_verified,
      "Verify your Google email before continuing.",
      403,
    );
    const userId = await transaction(pool, async (db) => {
      await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
        "google:" + p.sub,
      ]);
      const linked = (
        await db.query(
          "SELECT user_id FROM external_identities WHERE provider='google' AND subject=$1",
          [p.sub],
        )
      ).rows[0];
      if (linked) return linked.user_id;
      // Never turn an email match into an account takeover or a staff grant.
      const existing = (
        await db.query("SELECT id FROM users WHERE lower(email)=lower($1)", [
          p.email,
        ])
      ).rows[0];
      if (existing)
        throw new ApiError(
          409,
          "Sign in with your existing password, then link Google from Account.",
          "ACCOUNT_LINK_REQUIRED",
        );
      const authoritative =
        p.email.toLowerCase().endsWith("@gmail.com") || !!p.hd;
      if (
        !authoritative &&
        config.production &&
        (!process.env.SMTP_HOST ||
          process.env.EMAIL_DELIVERY_ENABLED !== "true")
      )
        throw new ApiError(
          503,
          "Email verification is not available yet.",
          "EMAIL_UNAVAILABLE",
        );
      const id = randomUUID();
      await db.query(
        "INSERT INTO users(id,name,email,password_hash,email_verified_at,marketplace_account) VALUES($1,$2,$3,NULL,CASE WHEN $4 THEN now() END,true)",
        [
          id,
          (p.name ?? p.email.split("@")[0]).slice(0, 120),
          p.email.toLowerCase(),
          authoritative,
        ],
      );
      await db.query(
        "INSERT INTO external_identities(provider,subject,user_id) VALUES('google',$1,$2)",
        [p.sub, id],
      );
      if (!authoritative) {
        const token = randomBytes(32).toString("hex");
        await db.query(
          "INSERT INTO identity_tokens(token_hash,user_id,purpose,expires_at) VALUES($1,$2,'verify_email',now()+interval '24 hours')",
          [hashToken(token), id],
        );
        await queueMail(
          db,
          null,
          id,
          p.email,
          "Verify your Kwadra email",
          `Your verification code: ${token}\nValid for 24 hours.`,
          randomUUID(),
        );
      }
      return id;
    });
    await establishSession(pool, res, userId, b.client, b.mfaCode);
  });
  app.post(
    "/api/v1/auth/google/link",
    authenticate(pool, true),
    async (req, res) => {
      const b = z
          .object({
            idToken: z.string().min(10).max(12000),
            password: z.string().max(256),
          })
          .strict()
          .parse(req.body),
        p = await verify(b.idToken);
      await transaction(pool, async (db) => {
        const user = (
          await db.query(
            "SELECT u.* FROM users u JOIN sessions s ON s.user_id=u.id WHERE u.id=$1 AND s.token_hash=$2 AND s.expires_at>now() AND NOT u.disabled FOR UPDATE OF u FOR SHARE OF s",
            [req.account!.userId, req.account!.tokenHash],
          )
        ).rows[0];
        requireCondition(
          user && (await verifyPassword(b.password, user.password_hash)),
          "Enter your current Kwadra password to link Google.",
          403,
        );
        requireCondition(
          p.email_verified &&
            p.email.toLowerCase() === user.email.toLowerCase(),
          "Choose the Google account with your Kwadra email address.",
          400,
        );
        await db
          .query(
            "INSERT INTO external_identities(provider,subject,user_id) VALUES('google',$1,$2) ON CONFLICT(provider,subject) DO UPDATE SET subject=excluded.subject WHERE external_identities.user_id=excluded.user_id RETURNING user_id",
            [p.sub, user.id],
          )
          .then((r) =>
            requireCondition(
              r.rowCount,
              "This Google account is already linked.",
              409,
            ),
          );
      });
      res.json({
        message: "Google account linked. You can use it next time you sign in.",
      });
    },
  );
}
