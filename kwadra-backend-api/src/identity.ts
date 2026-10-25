import { randomUUID, randomBytes } from "node:crypto";
import { z } from "zod";
import type pg from "pg";
import type { RequestHandler } from "express";
import { transaction, type Db } from "./db.js";
import {
  hashPassword,
  verifyPassword,
  hashToken,
  canManage,
  propertyAccess,
  type Context,
} from "./auth.js";
import { ApiError, requireCondition } from "./errors.js";
import { queueMail } from "./mail.js";
import { audit } from "./operations.js";

const tokenSchema = z.string().regex(/^[a-f0-9]{64}$/);
export function identityRoutes(pool: pg.Pool) {
  return {
    resend: (async (req, res) => {
      const { email } = z
        .object({ email: z.email().max(254) })
        .strict()
        .parse(req.body);
      await transaction(pool, async (db) => {
        const user = (
          await db.query(
            "SELECT id,email FROM users WHERE lower(email)=lower($1) AND NOT disabled AND email_verified_at IS NULL FOR UPDATE",
            [email.trim()],
          )
        ).rows[0];
        if (!user) return;
        const recent = await db.query(
          "SELECT 1 FROM identity_tokens WHERE user_id=$1 AND purpose='verify_email' AND created_at>now()-interval '60 seconds'",
          [user.id],
        );
        if (recent.rowCount) return;
        await db.query(
          "UPDATE identity_tokens SET consumed_at=now() WHERE user_id=$1 AND purpose='verify_email' AND consumed_at IS NULL",
          [user.id],
        );
        const token = randomBytes(32).toString("hex");
        await db.query(
          "INSERT INTO identity_tokens(token_hash,user_id,purpose,expires_at) VALUES($1,$2,'verify_email',now()+interval '24 hours')",
          [hashToken(token), user.id],
        );
        await queueMail(
          db,
          null,
          user.id,
          user.email,
          "Verify your Kwadra email",
          `Your newest verification code: ${token}\nValid for 24 hours. Previous codes no longer work.`,
          randomUUID(),
        );
      });
      res.json({
        message:
          "If the account needs verification, an email has been queued. Allow a minute before requesting another.",
      });
    }) as RequestHandler,
    verify: (async (req, res) => {
      const { token } = z
        .object({ token: tokenSchema })
        .strict()
        .parse(req.body);
      await transaction(pool, async (db) => {
        const row = (
          await db.query(
            "SELECT t.* FROM identity_tokens t JOIN users u ON u.id=t.user_id WHERE token_hash=$1 AND purpose='verify_email' AND consumed_at IS NULL AND expires_at>now() AND NOT u.disabled FOR UPDATE OF t,u",
            [hashToken(token)],
          )
        ).rows[0];
        requireCondition(
          row,
          "This verification code is invalid or expired.",
          400,
        );
        await db.query("UPDATE users SET email_verified_at=now() WHERE id=$1", [
          row.user_id,
        ]);
        await db.query(
          "UPDATE identity_tokens SET consumed_at=now() WHERE token_hash=$1",
          [hashToken(token)],
        );
      });
      res.json({ message: "Email verified. You can sign in." });
    }) as RequestHandler,
    recover: (async (req, res) => {
      const { email } = z
        .object({ email: z.email().max(254) })
        .strict()
        .parse(req.body);
      await transaction(pool, async (db) => {
        const user = (
          await db.query(
            `SELECT u.id,o.organization_id FROM users u LEFT JOIN memberships o ON o.user_id=u.id AND o.active
          WHERE lower(u.email)=lower($1) AND NOT u.disabled AND (o.organization_id IS NOT NULL OR u.marketplace_account) ORDER BY o.organization_id NULLS LAST LIMIT 1`,
            [email],
          )
        ).rows[0];
        if (user) {
          const token = randomBytes(32).toString("hex");
          await db.query(
            "UPDATE identity_tokens SET consumed_at=now() WHERE user_id=$1 AND purpose='recover_password' AND consumed_at IS NULL",
            [user.id],
          );
          await db.query(
            "INSERT INTO identity_tokens(token_hash,user_id,purpose,expires_at) VALUES($1,$2,'recover_password',now()+interval '30 minutes')",
            [hashToken(token), user.id],
          );
          await queueMail(
            db,
            user.organization_id,
            user.id,
            email,
            "Reset your Kwadra password",
            `Your password reset code: ${token}\nValid for 30 minutes. If you did not request this, ignore this message.`,
            randomUUID(),
          );
        }
      });
      res.json({
        message:
          "If the account is eligible, a password reset code has been queued.",
      });
    }) as RequestHandler,
    reset: (async (req, res) => {
      const b = z
        .object({ token: tokenSchema, password: z.string().min(12).max(256) })
        .strict()
        .parse(req.body);
      const passwordHash = await hashPassword(b.password);
      await transaction(pool, async (db) => {
        const row = (
          await db.query(
            "SELECT t.* FROM identity_tokens t JOIN users u ON u.id=t.user_id WHERE token_hash=$1 AND purpose='recover_password' AND consumed_at IS NULL AND expires_at>now() AND NOT u.disabled FOR UPDATE OF t",
            [hashToken(b.token)],
          )
        ).rows[0];
        requireCondition(row, "This reset code is invalid or expired.", 400);
        await db.query("UPDATE users SET password_hash=$2 WHERE id=$1", [
          row.user_id,
          passwordHash,
        ]);
        await db.query(
          "UPDATE identity_tokens SET consumed_at=now() WHERE user_id=$1 AND purpose='recover_password' AND consumed_at IS NULL",
          [row.user_id],
        );
        await db.query("DELETE FROM sessions WHERE user_id=$1", [row.user_id]);
      });
      res.json({
        message: "Password changed. Sign in with your new password.",
      });
    }) as RequestHandler,
    accept: (async (req, res) => {
      const b = z
        .object({
          token: tokenSchema,
          email: z.email().max(254),
          name: z.string().trim().min(1).max(120),
          password: z.string().min(12).max(256),
        })
        .strict()
        .parse(req.body);
      await transaction(pool, async (db) => {
        const invite = (
          await db.query(
            "SELECT * FROM invitations WHERE token_hash=$1 AND expires_at>now() AND accepted_at IS NULL FOR UPDATE",
            [hashToken(b.token)],
          )
        ).rows[0];
        requireCondition(
          invite && invite.email.toLowerCase() === b.email.toLowerCase(),
          "Invitation is invalid, expired, or belongs to another email.",
          400,
        );
        let user = (
          await db.query(
            "SELECT * FROM users WHERE lower(email)=lower($1) FOR UPDATE",
            [b.email],
          )
        ).rows[0];
        if (user)
          requireCondition(
            !user.disabled &&
              (await verifyPassword(b.password, user.password_hash)),
            "Use the existing account password to accept this invitation.",
            403,
          );
        else {
          user = { id: randomUUID() };
          await db.query(
            "INSERT INTO users(id,name,email,password_hash,email_verified_at) VALUES($1,$2,$3,$4,now())",
            [
              user.id,
              b.name,
              b.email.toLowerCase(),
              await hashPassword(b.password),
            ],
          );
        }
        const membership = (
          await db.query(
            "SELECT * FROM memberships WHERE organization_id=$1 AND user_id=$2",
            [invite.organization_id, user.id],
          )
        ).rows[0];
        requireCondition(
          !membership || !membership.active,
          "This account already belongs to this organization.",
          409,
        );
        await db.query(
          `INSERT INTO memberships(organization_id,user_id,role,all_properties) VALUES($1,$2,$3,false)
          ON CONFLICT(organization_id,user_id) DO UPDATE SET role=excluded.role,active=true,all_properties=false`,
          [invite.organization_id, user.id, invite.role],
        );
        if (invite.role === "tenant") {
          const tenant = (
            await db.query(
              "SELECT * FROM tenants WHERE organization_id=$1 AND id=$2 FOR UPDATE",
              [invite.organization_id, invite.tenant_id],
            )
          ).rows[0];
          requireCondition(
            tenant && (!tenant.user_id || tenant.user_id === user.id),
            "Tenant profile is already linked to another account.",
            409,
          );
          await db.query(
            "UPDATE tenants SET user_id=$3,revision=revision+1 WHERE organization_id=$1 AND id=$2",
            [invite.organization_id, invite.tenant_id, user.id],
          );
        } else
          for (const propertyId of invite.property_ids)
            await db.query(
              "INSERT INTO property_assignments(organization_id,user_id,property_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING",
              [invite.organization_id, user.id, propertyId],
            );
        await db.query("UPDATE invitations SET accepted_at=now() WHERE id=$1", [
          invite.id,
        ]);
        await db.query(
          "UPDATE users SET email_verified_at=coalesce(email_verified_at,now()) WHERE id=$1",
          [user.id],
        );
        await audit(
          db,
          {
            userId: user.id,
            orgId: invite.organization_id,
            role: invite.role,
            allProperties: false,
            tokenHash: "",
            csrf: "",
          },
          "Invitation accepted",
          invite.role,
          "settings",
          invite.id,
        );
      });
      res.json({ message: "Invitation accepted. You can sign in." });
    }) as RequestHandler,
  };
}

export async function teamSnapshot(db: Db, ctx: Context) {
  canManage(ctx);
  const members = (
    await db.query(
      `SELECT u.id,u.name,u.email,m.role,m.active,m.all_properties AS "allProperties",
    coalesce((SELECT json_agg(a.property_id) FROM property_assignments a WHERE a.organization_id=m.organization_id AND a.user_id=m.user_id),'[]') AS "propertyIds"
    FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.organization_id=$1 ORDER BY u.name`,
      [ctx.orgId],
    )
  ).rows;
  const invitations = (
    await db.query(
      'SELECT id,email,role,expires_at AS "expiresAt",accepted_at AS "acceptedAt" FROM invitations WHERE organization_id=$1 ORDER BY expires_at DESC',
      [ctx.orgId],
    )
  ).rows;
  return { members, invitations };
}
export async function inviteMember(db: Db, ctx: Context, input: unknown) {
  canManage(ctx);
  const b = z
    .object({
      email: z.email().max(254),
      role: z.enum(["admin", "staff", "viewer", "tenant"]),
      propertyIds: z.array(z.uuid()).max(200).default([]),
      tenantId: z.uuid().optional(),
    })
    .strict()
    .parse(input);
  if (ctx.role === "admin")
    requireCondition(
      b.role !== "admin",
      "Only the owner can invite administrators.",
      403,
    );
  for (const id of b.propertyIds) await propertyAccess(db, ctx, id);
  if (b.role === "tenant") {
    requireCondition(b.tenantId, "Select a tenant profile.");
    const tenant = (
      await db.query(
        "SELECT * FROM tenants WHERE organization_id=$1 AND id=$2",
        [ctx.orgId, b.tenantId],
      )
    ).rows[0];
    requireCondition(
      tenant && tenant.email.toLowerCase() === b.email.toLowerCase(),
      "The invitation email must match the tenant profile.",
    );
    requireCondition(
      !tenant.user_id,
      "This tenant is already linked to an account.",
      409,
    );
    requireCondition(
      !b.propertyIds.length,
      "Tenant permissions derive from leases, not staff property assignments.",
    );
  } else
    requireCondition(
      !b.tenantId,
      "Tenant profile is only valid for tenant invitations.",
    );
  const active = await db.query(
    "SELECT 1 FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.organization_id=$1 AND lower(u.email)=lower($2) AND m.active",
    [ctx.orgId, b.email],
  );
  requireCondition(
    !active.rowCount,
    "This email already has access to the organization.",
    409,
  );
  const id = randomUUID(),
    token = randomBytes(32).toString("hex");
  await db.query(
    "UPDATE invitations SET expires_at=now() WHERE organization_id=$1 AND lower(email)=lower($2) AND accepted_at IS NULL",
    [ctx.orgId, b.email],
  );
  await db.query(
    "INSERT INTO invitations(id,organization_id,email,role,token_hash,expires_at,created_by,tenant_id,property_ids) VALUES($1,$2,$3,$4,$5,now()+interval '72 hours',$6,$7,$8)",
    [
      id,
      ctx.orgId,
      b.email.toLowerCase(),
      b.role,
      hashToken(token),
      ctx.userId,
      b.tenantId ?? null,
      b.propertyIds,
    ],
  );
  await queueMail(
    db,
    ctx.orgId,
    null,
    b.email,
    "Your Kwadra invitation",
    `You have been invited as ${b.role}.\nInvitation code: ${token}\nUse your existing password if you already have an account. This code expires in 72 hours.`,
    id,
  );
  await audit(db, ctx, "Invitation sent", b.role, "settings", id);
  return { id, message: "Invitation queued for delivery." };
}
export async function updateMember(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  canManage(ctx);
  const b = z
    .object({
      role: z.enum(["admin", "staff", "viewer", "tenant"]),
      active: z.boolean(),
      allProperties: z.boolean().default(false),
      propertyIds: z.array(z.uuid()).max(200).default([]),
    })
    .strict()
    .parse(input);
  const old = (
    await db.query(
      "SELECT * FROM memberships WHERE organization_id=$1 AND user_id=$2 FOR UPDATE",
      [ctx.orgId, id],
    )
  ).rows[0];
  requireCondition(old, "Member not found.", 404);
  requireCondition(
    old.role !== "owner",
    "The owner cannot be changed from this screen.",
    403,
  );
  if (ctx.role === "admin")
    requireCondition(
      old.role !== "admin" && b.role !== "admin",
      "Only the owner can change administrator access.",
      403,
    );
  requireCondition(
    (old.role === "tenant") === (b.role === "tenant"),
    "Tenant and staff accounts cannot be converted into each other.",
  );
  if (b.role === "tenant")
    requireCondition(
      !b.allProperties && !b.propertyIds.length,
      "Tenant access derives from leases.",
    );
  for (const p of b.propertyIds) await propertyAccess(db, ctx, p);
  await db.query(
    "UPDATE memberships SET role=$3,active=$4,all_properties=$5 WHERE organization_id=$1 AND user_id=$2",
    [ctx.orgId, id, b.role, b.active, b.allProperties],
  );
  await db.query(
    "DELETE FROM property_assignments WHERE organization_id=$1 AND user_id=$2",
    [ctx.orgId, id],
  );
  for (const p of b.propertyIds)
    await db.query(
      "INSERT INTO property_assignments(organization_id,user_id,property_id) VALUES($1,$2,$3)",
      [ctx.orgId, id, p],
    );
  await audit(
    db,
    ctx,
    "Member permissions updated",
    `${b.role} · ${b.active ? "active" : "revoked"}`,
    "settings",
    id,
  );
  return { id };
}
