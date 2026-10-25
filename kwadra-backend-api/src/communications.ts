import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { Db } from "./db.js";
import { canWrite, propertyAccess, type Context } from "./auth.js";
import { audit } from "./operations.js";
import { notify } from "./mail.js";

export async function announce(db: Db, ctx: Context, input: unknown) {
  canWrite(ctx);
  const b = z
    .object({
      propertyId: z.uuid(),
      title: z.string().trim().min(1).max(160),
      body: z.string().trim().min(1).max(8000),
    })
    .strict()
    .parse(input);
  await propertyAccess(db, ctx, b.propertyId);
  const id = randomUUID();
  await db.query(
    "INSERT INTO announcements(id,organization_id,property_id,title,body,published_at) VALUES($1,$2,$3,$4,$5,now())",
    [id, ctx.orgId, b.propertyId, b.title, b.body],
  );
  const recipients = (
    await db.query(
      `SELECT DISTINCT t.user_id FROM tenants t JOIN lease_participants lp ON lp.organization_id=t.organization_id AND lp.tenant_id=t.id
    JOIN leases l ON l.organization_id=lp.organization_id AND l.id=lp.lease_id JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id
    JOIN memberships m ON m.organization_id=t.organization_id AND m.user_id=t.user_id AND m.active AND m.role='tenant'
    WHERE t.organization_id=$1 AND u.property_id=$2 AND l.occupancy @> (now() AT TIME ZONE 'Asia/Manila')::date AND t.user_id IS NOT NULL`,
      [ctx.orgId, b.propertyId],
    )
  ).rows;
  for (const r of recipients)
    await notify(
      db,
      ctx.orgId,
      r.user_id,
      b.title,
      b.body,
      "announcement:" + id,
      true,
    );
  await audit(
    db,
    ctx,
    "Announcement published",
    b.title,
    "communication",
    id,
    b.propertyId,
  );
  return { id, recipients: recipients.length };
}
export async function notificationSnapshot(db: Db, ctx: Context) {
  return {
    notifications: (
      await db.query(
        'SELECT id,title,body,created_at AS created,read_at AS "readAt" FROM notifications WHERE organization_id=$1 AND recipient_id=$2 ORDER BY created_at DESC LIMIT 200',
        [ctx.orgId, ctx.userId],
      )
    ).rows,
    preferences: (
      await db.query(
        'SELECT in_app AS "inApp",email FROM notification_preferences WHERE user_id=$1',
        [ctx.userId],
      )
    ).rows[0] ?? { inApp: true, email: false },
  };
}
export async function updatePreferences(db: Db, ctx: Context, input: unknown) {
  const b = z
    .object({ inApp: z.boolean(), email: z.boolean() })
    .strict()
    .parse(input);
  await db.query(
    "INSERT INTO notification_preferences(user_id,in_app,email) VALUES($1,$2,$3) ON CONFLICT(user_id) DO UPDATE SET in_app=excluded.in_app,email=excluded.email",
    [ctx.userId, b.inApp, b.email],
  );
  return b;
}
