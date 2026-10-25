import {
  createHash,
  randomBytes,
  randomUUID,
  scrypt as scryptCallback,
  timingSafeEqual,
} from "node:crypto";
import { promisify } from "node:util";
import type { RequestHandler, Request, Response } from "express";
import type pg from "pg";
import { z } from "zod";
import { config } from "./config.js";
import { ApiError } from "./errors.js";
import { transaction, type Db } from "./db.js";
import argon2 from "argon2";
import { queueMail } from "./mail.js";
import { establishSession, revokeSession } from "./sessions.js";

const scrypt = promisify(scryptCallback);
export const hashToken = (token: string) =>
  createHash("sha256").update(token).digest("hex");
export async function hashPassword(password: string) {
  return argon2.hash(password, {
    type: argon2.argon2id,
    memoryCost: 65536,
    timeCost: 3,
    parallelism: 1,
  });
}
// Keep unknown-account checks on the same current password hashing policy.
const dummyPasswordHash = hashPassword(randomBytes(32).toString("hex"));
export async function verifyPassword(password: string, stored: string | null) {
  if (!stored) {
    await argon2.verify(await dummyPasswordHash, password);
    return false;
  }
  if (stored.startsWith("$argon2")) return argon2.verify(stored, password);
  const [kind, salt, encoded] = stored.split(":");
  if (kind !== "scrypt" || !salt || !encoded) return false;
  const expected = Buffer.from(encoded, "hex");
  const actual = (await scrypt(password, salt, 64)) as Buffer;
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

export type Context = {
  userId: string;
  orgId: string;
  role: "owner" | "admin" | "staff" | "viewer" | "tenant";
  allProperties: boolean;
  tokenHash: string;
  csrf: string;
  platformAdmin?: boolean;
};
export type AccountContext = Pick<
  Context,
  "userId" | "tokenHash" | "csrf" | "platformAdmin"
>;
declare global {
  namespace Express {
    interface Request {
      auth?: Context;
      account?: AccountContext;
    }
  }
}

function sessionToken(req: Request) {
  if (req.headers.authorization?.startsWith("Bearer "))
    return req.headers.authorization.slice(7);
  const cookie = req.headers.cookie
    ?.split(";")
    .map((c) => c.trim())
    .find((c) => c.startsWith("kwadra_session="));
  return cookie?.slice("kwadra_session=".length);
}
export function authenticate(pool: pg.Pool, personal = false): RequestHandler {
  return async (req, _res, next) => {
    const token = sessionToken(req);
    if (!token || !/^[a-f0-9]{64}$/.test(token))
      throw new ApiError(401, "Sign in to continue.", "UNAUTHENTICATED");
    const result = await pool.query(
      `SELECT s.*, u.disabled,u.platform_admin FROM sessions s JOIN users u ON u.id=s.user_id
      WHERE s.token_hash=$1 AND s.expires_at>now() AND NOT u.disabled`,
      [hashToken(token)],
    );
    if (!result.rowCount)
      throw new ApiError(
        401,
        "Your session expired. Please sign in again.",
        "UNAUTHENTICATED",
      );
    const session = result.rows[0];
    if (
      !["GET", "HEAD", "OPTIONS"].includes(req.method) &&
      !req.headers.authorization &&
      req.header("X-CSRF-Token") !== session.csrf_token
    )
      throw new ApiError(
        403,
        "The session security token is missing. Sign in again.",
        "CSRF_FAILED",
      );
    req.account = {
      userId: session.user_id,
      tokenHash: session.token_hash,
      csrf: session.csrf_token,
      platformAdmin: session.platform_admin && session.mfa_verified,
    };
    if (personal) {
      next();
      return;
    }
    let orgId = req.header("X-Organization-Id");
    if (!orgId && req.path === "/auth/me")
      orgId = (await membershipsFor(pool, session.user_id))[0]?.id;
    if (!orgId || !z.uuid().safeParse(orgId).success)
      throw new ApiError(
        400,
        "Select a valid organization.",
        "ORGANIZATION_REQUIRED",
      );
    const memberships = await pool.query(
      "SELECT * FROM memberships WHERE organization_id=$1 AND user_id=$2 AND active",
      [orgId, session.user_id],
    );
    if (!memberships.rowCount)
      throw new ApiError(
        403,
        "You do not have access to this organization.",
        "FORBIDDEN",
      );
    if (
      !["GET", "HEAD", "OPTIONS"].includes(req.method) &&
      !req.headers.authorization &&
      req.header("X-CSRF-Token") !== session.csrf_token
    ) {
      throw new ApiError(
        403,
        "The session security token is missing. Sign in again.",
        "CSRF_FAILED",
      );
    }
    const membership = memberships.rows[0];
    req.auth = {
      userId: session.user_id,
      orgId,
      role: membership.role,
      allProperties:
        membership.all_properties ||
        ["owner", "admin"].includes(membership.role),
      tokenHash: session.token_hash,
      csrf: session.csrf_token,
      platformAdmin: session.platform_admin && session.mfa_verified,
    };
    next();
  };
}
export function canWrite(ctx: Context) {
  if (ctx.role === "viewer" || ctx.role === "tenant")
    throw new ApiError(
      403,
      "This account cannot change landlord records.",
      "FORBIDDEN",
    );
}
export function canManage(ctx: Context) {
  if (!["owner", "admin"].includes(ctx.role))
    throw new ApiError(
      403,
      "An owner or administrator must make this change.",
      "FORBIDDEN",
    );
}
export async function propertyAccess(db: Db, ctx: Context, id: string) {
  const result = await db.query(
    `SELECT p.* FROM properties p WHERE p.organization_id=$1 AND p.id=$2
    AND ($3::boolean OR EXISTS (SELECT 1 FROM property_assignments a WHERE a.organization_id=p.organization_id
      AND a.property_id=p.id AND a.user_id=$4))`,
    [ctx.orgId, id, ctx.allProperties, ctx.userId],
  );
  if (!result.rowCount)
    throw new ApiError(404, "Property not found or unavailable.", "NOT_FOUND");
  return result.rows[0];
}
export async function unitAccess(db: Db, ctx: Context, id: string) {
  const result = await db.query(
    "SELECT * FROM units WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id],
  );
  if (!result.rowCount)
    throw new ApiError(404, "Unit not found or unavailable.", "NOT_FOUND");
  const unit = result.rows[0];
  await propertyAccess(db, ctx, unit.property_id);
  return unit;
}
export async function membershipsFor(pool: pg.Pool, userId: string) {
  const result = await pool.query(
    `SELECT o.id,o.name,m.role,u.platform_admin FROM memberships m JOIN organizations o ON o.id=m.organization_id JOIN users u ON u.id=m.user_id
    WHERE m.user_id=$1 AND m.active ORDER BY o.created_at,o.id`,
    [userId],
  );
  return result.rows;
}
export function authRoutes(pool: pg.Pool) {
  return {
    login: (async (req, res) => {
      const body = z
        .object({
          email: z.email().max(254),
          password: z.string().min(1).max(256),
          client: z.enum(["web", "native"]).default("web"),
          mfaCode: z.string().max(6).optional(),
        })
        .strict()
        .parse(req.body);
      const user = (
        await pool.query(
          "SELECT * FROM users WHERE lower(email)=lower($1) AND NOT disabled",
          [body.email.trim()],
        )
      ).rows[0];
      // Same expensive hash when an email is unknown, avoiding a fast account probe.
      if (
        !(await verifyPassword(
          body.password,
          user?.password_hash ?? (await dummyPasswordHash),
        )) ||
        !user
      )
        throw new ApiError(
          401,
          "Email or password is incorrect.",
          "INVALID_CREDENTIALS",
        );
      if (user.password_hash?.startsWith("scrypt:")) {
        const upgraded = await hashPassword(body.password);
        const changed = await pool.query(
          "UPDATE users SET password_hash=$2 WHERE id=$1 AND password_hash=$3",
          [user.id, upgraded, user.password_hash],
        );
        if (!changed.rowCount)
          throw new ApiError(
            401,
            "Your credentials changed. Sign in again.",
            "INVALID_CREDENTIALS",
          );
        user.password_hash = upgraded;
      }
      await establishSession(
        pool,
        res,
        user.id,
        body.client,
        body.mfaCode,
        user.password_hash,
      );
    }) as RequestHandler,
    register: (async (req, res) => {
      const body = z
        .object({
          name: z.string().trim().min(1).max(120),
          email: z.email().max(254),
          password: z.string().min(12).max(256),
          organization: z.string().trim().min(1).max(160),
        })
        .strict()
        .parse(req.body);
      const userId = randomUUID(),
        orgId = randomUUID(),
        passwordHash = await hashPassword(body.password);
      await transaction(pool, async (db) => {
        await db.query(
          "INSERT INTO users(id,name,email,password_hash) VALUES($1,$2,$3,$4)",
          [userId, body.name, body.email.trim().toLowerCase(), passwordHash],
        );
        await db.query("INSERT INTO organizations(id,name) VALUES($1,$2)", [
          orgId,
          body.organization,
        ]);
        await db.query(
          "INSERT INTO memberships(organization_id,user_id,role,all_properties) VALUES($1,$2,'owner',true)",
          [orgId, userId],
        );
        const verification = randomBytes(32).toString("hex");
        await db.query(
          "INSERT INTO identity_tokens(token_hash,user_id,purpose,expires_at) VALUES($1,$2,'verify_email',now()+interval '24 hours')",
          [hashToken(verification), userId],
        );
        await queueMail(
          db,
          orgId,
          userId,
          body.email.toLowerCase(),
          "Verify your Kwadra email",
          `Your verification code: ${verification}\nValid for 24 hours.`,
          randomUUID(),
        );
      });
      res.status(201).json({
        message: "Account created. Check your email for a verification code.",
      });
    }) as RequestHandler,
    me: (async (req, res) => {
      const ctx = req.account!;
      const user = (
        await pool.query(
          'SELECT id,name,email,platform_admin AS "platformAdmin",marketplace_account AS "marketplaceAccount" FROM users WHERE id=$1',
          [ctx.userId],
        )
      ).rows[0];
      res.json({
        user,
        organizations: await membershipsFor(pool, ctx.userId),
        csrfToken: ctx.csrf,
        capabilities: { liveNotifications: true },
      });
    }) as RequestHandler,
    logout: (async (req, res) => {
      await revokeSession(pool, req.account!.tokenHash);
      res.clearCookie("kwadra_session", {
        path: "/api/v1",
        httpOnly: true,
        secure: config.cookieSecure,
        sameSite: "lax",
      });
      res.json({ message: "Signed out." });
    }) as RequestHandler,
  };
}
