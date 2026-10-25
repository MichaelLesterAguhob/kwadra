import { randomBytes, randomUUID, createHash } from "node:crypto";
import type { Response } from "express";
import type pg from "pg";
import { transaction, type Db } from "./db.js";
import { config } from "./config.js";
import { ApiError } from "./errors.js";
import { decryptSecret, verifyTotp } from "./security.js";

const hash = (value: string) =>
  createHash("sha256").update(value).digest("hex");
export type ClientKind = "web" | "native";
async function responseFor(
  db: Db,
  user: any,
  token: string,
  csrf: string,
  refreshToken?: string,
) {
  const organizations = (
    await db.query(
      `SELECT o.id,o.name,m.role,u.platform_admin FROM memberships m
    JOIN organizations o ON o.id=m.organization_id JOIN users u ON u.id=m.user_id
    WHERE m.user_id=$1 AND m.active ORDER BY o.created_at,o.id`,
      [user.id],
    )
  ).rows;
  if (!organizations.length && !user.marketplace_account)
    throw new ApiError(
      403,
      "This account has no active organization.",
      "FORBIDDEN",
    );
  return {
    user: {
      id: user.id,
      name: user.name,
      email: user.email,
      platformAdmin: !!user.platform_admin,
      marketplaceAccount: !!user.marketplace_account,
    },
    organizations,
    capabilities: { liveNotifications: true },
    csrfToken: csrf,
    token,
    ...(refreshToken ? { refreshToken } : {}),
  };
}
function send(
  res: Response,
  result: Awaited<ReturnType<typeof responseFor>>,
  client: ClientKind,
) {
  if (client === "web") {
    res.cookie("kwadra_session", result.token, {
      httpOnly: true,
      secure: config.cookieSecure,
      sameSite: "lax",
      path: "/api/v1",
      maxAge: 12 * 60 * 60 * 1000,
    });
    const { token, refreshToken, ...safe } = result;
    res.json(safe);
  } else res.json(result);
}
export async function establishSession(
  pool: pg.Pool,
  res: Response,
  userId: string,
  client: ClientKind,
  mfaCode?: string,
  verifiedHash?: string,
) {
  const result = await transaction(pool, async (db) => {
    const user = (
      await db.query(
        "SELECT * FROM users WHERE id=$1 AND NOT disabled FOR UPDATE",
        [userId],
      )
    ).rows[0];
    if (!user) throw new ApiError(401, "Sign in again.", "UNAUTHENTICATED");
    if (verifiedHash !== undefined && user.password_hash !== verifiedHash)
      throw new ApiError(
        401,
        "Your credentials changed. Sign in again.",
        "INVALID_CREDENTIALS",
      );
    if (!user.email_verified_at)
      throw new ApiError(
        403,
        "Verify your email address before signing in.",
        "EMAIL_UNVERIFIED",
      );
    let counter: number | null = null;
    if (user.platform_admin) {
      if (!mfaCode || !user.mfa_secret)
        throw new ApiError(
          403,
          "Enter your authenticator code.",
          "MFA_REQUIRED",
        );
      counter = verifyTotp(
        await decryptSecret(user.mfa_secret),
        mfaCode,
        user.last_mfa_counter === null ? null : Number(user.last_mfa_counter),
      );
      if (counter === null)
        throw new ApiError(
          403,
          "Authenticator code is invalid or already used.",
          "MFA_INVALID",
        );
      await db.query("UPDATE users SET last_mfa_counter=$2 WHERE id=$1", [
        userId,
        counter,
      ]);
    }
    const token = randomBytes(32).toString("hex"),
      csrf = randomBytes(32).toString("hex");
    let family: string | null = null,
      refreshToken: string | undefined;
    if (client === "native") {
      family = randomUUID();
      refreshToken = randomBytes(32).toString("hex");
      await db.query(
        "INSERT INTO native_session_families(id,user_id,expires_at) VALUES($1,$2,now()+$3::interval)",
        [family, userId, user.platform_admin ? "12 hours" : "30 days"],
      );
      await db.query(
        "INSERT INTO refresh_credentials(token_hash,family_id) VALUES($1,$2)",
        [hash(refreshToken), family],
      );
    }
    await db.query(
      "INSERT INTO sessions(token_hash,user_id,csrf_token,expires_at,mfa_verified,mfa_counter,family_id) VALUES($1,$2,$3,now()+interval '12 hours',$4,$5,$6)",
      [hash(token), userId, csrf, !!user.platform_admin, counter, family],
    );
    return responseFor(db, user, token, csrf, refreshToken);
  });
  send(res, result, client);
}
export async function rotateSession(
  pool: pg.Pool,
  res: Response,
  token: string,
) {
  const result = await transaction(pool, async (db) => {
    const credential = (
      await db.query(
        "SELECT family_id FROM refresh_credentials WHERE token_hash=$1",
        [hash(token)],
      )
    ).rows[0];
    if (!credential) return null;
    const owner = (
      await db.query(
        "SELECT user_id FROM native_session_families WHERE id=$1",
        [credential.family_id],
      )
    ).rows[0];
    if (!owner) return null;
    const user = (
      await db.query(
        "SELECT * FROM users WHERE id=$1 AND NOT disabled AND email_verified_at IS NOT NULL FOR SHARE",
        [owner.user_id],
      )
    ).rows[0];
    if (!user) return null;
    const family = (
      await db.query(
        "SELECT * FROM native_session_families WHERE id=$1 AND revoked_at IS NULL AND expires_at>now() FOR UPDATE",
        [credential.family_id],
      )
    ).rows[0];
    if (!family) return null;
    const fresh = (
      await db.query(
        "SELECT consumed_at FROM refresh_credentials WHERE token_hash=$1",
        [hash(token)],
      )
    ).rows[0];
    if (fresh?.consumed_at) {
      await db.query(
        "UPDATE native_session_families SET revoked_at=now() WHERE id=$1",
        [family.id],
      );
      await db.query("DELETE FROM sessions WHERE family_id=$1", [family.id]);
      return null; // Commit replay revocation before returning 401.
    }
    const previous = (
      await db.query(
        "SELECT mfa_verified,mfa_counter FROM sessions WHERE family_id=$1 LIMIT 1",
        [family.id],
      )
    ).rows[0];
    if (!previous) return null;
    const access = randomBytes(32).toString("hex"),
      refresh = randomBytes(32).toString("hex"),
      csrf = randomBytes(32).toString("hex");
    await db.query(
      "UPDATE refresh_credentials SET consumed_at=now() WHERE token_hash=$1",
      [hash(token)],
    );
    await db.query(
      "INSERT INTO refresh_credentials(token_hash,family_id) VALUES($1,$2)",
      [hash(refresh), family.id],
    );
    await db.query(
      "INSERT INTO sessions(token_hash,user_id,csrf_token,expires_at,mfa_verified,mfa_counter,family_id) VALUES($1,$2,$3,least(now()+interval '12 hours',$4::timestamptz),$5,$6,$7)",
      [
        hash(access),
        user.id,
        csrf,
        family.expires_at,
        previous.mfa_verified,
        previous.mfa_counter,
        family.id,
      ],
    );
    await db.query(
      "DELETE FROM sessions WHERE family_id=$1 AND token_hash<>$2",
      [family.id, hash(access)],
    );
    return responseFor(db, user, access, csrf, refresh);
  });
  if (!result)
    throw new ApiError(
      401,
      "Your saved session expired. Sign in again.",
      "UNAUTHENTICATED",
    );
  send(res, result, "native");
}
export async function revokeSession(pool: pg.Pool, tokenHash: string) {
  await transaction(pool, async (db) => {
    const row = (
      await db.query("SELECT family_id FROM sessions WHERE token_hash=$1", [
        tokenHash,
      ])
    ).rows[0];
    if (row?.family_id)
      await db.query("DELETE FROM native_session_families WHERE id=$1", [
        row.family_id,
      ]);
    else
      await db.query("DELETE FROM sessions WHERE token_hash=$1", [tokenHash]);
  });
}
