import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { Db } from "./db.js";
import type { Context } from "./auth.js";
import { requireCondition } from "./errors.js";
import { audit, checkRevision } from "./operations.js";
import { privateListing, vacancy } from "./marketplace.js";
import { notify } from "./mail.js";

export function platformAccess(ctx: Context) {
  requireCondition(
    ctx.platformAdmin,
    "Platform moderation requires an administrator session verified with MFA.",
    403,
  );
}
async function platformEvent(
  db: Db,
  ctx: Context,
  action: string,
  id: string,
  reason: string,
) {
  await db.query(
    "INSERT INTO platform_events(id,actor_id,action,resource_id,reason) VALUES($1,$2,$3,$4,$5)",
    [randomUUID(), ctx.userId, action, id, reason],
  );
}
export async function moderationSnapshot(db: Db, ctx: Context) {
  platformAccess(ctx);
  const verifications = (
    await db.query(`SELECT v.organization_id AS "organizationId",o.name,v.status,v.notes,v.attachment_id AS "attachmentId",v.revision
    FROM publisher_verifications v JOIN organizations o ON o.id=v.organization_id ORDER BY v.status,v.reviewed_at NULLS FIRST`)
  ).rows;
  const listings = (
    await db.query(`SELECT l.id,l.organization_id AS "organizationId",o.name AS organization,l.title,l.description,l.location_label AS location,l.status,l.revision,
    EXISTS(SELECT 1 FROM listing_photos p WHERE p.organization_id=l.organization_id AND p.listing_id=l.id) AS "hasPhotos",
    (SELECT count(*)::int FROM listings other WHERE other.id<>l.id AND lower(other.title)=lower(l.title) AND lower(other.location_label)=lower(l.location_label)) AS "duplicateFlags"
    FROM listings l JOIN organizations o ON o.id=l.organization_id WHERE l.status<>'draft' ORDER BY l.updated_at DESC LIMIT 200`)
  ).rows;
  const reports = (
    await db.query(
      'SELECT r.id,r.listing_id AS "listingId",r.reason,r.status,l.title,r.created_at AS created FROM listing_reports r JOIN listings l ON l.id=r.listing_id ORDER BY r.created_at DESC LIMIT 200',
    )
  ).rows;
  const cases = (
    await db.query(
      'SELECT c.id,c.listing_id AS "listingId",l.title,c.reason,c.status FROM moderation_cases c JOIN listings l ON l.id=c.listing_id ORDER BY c.created_at DESC LIMIT 200',
    )
  ).rows;
  const events = (
    await db.query(
      'SELECT id,action,resource_id AS "resourceId",reason,created_at AS created FROM platform_events ORDER BY created_at DESC LIMIT 200',
    )
  ).rows;
  const caseEvents = (
    await db.query(
      'SELECT id,case_id AS "caseId",detail,created_at AS created FROM moderation_events ORDER BY created_at DESC LIMIT 500',
    )
  ).rows;
  return { verifications, listings, reports, cases, events, caseEvents };
}
export async function reviewPublisher(
  db: Db,
  ctx: Context,
  orgId: string,
  input: unknown,
) {
  platformAccess(ctx);
  const b = z
    .object({
      revision: z.number().int().positive(),
      status: z.enum(["verified", "rejected"]),
      reason: z.string().trim().min(10).max(2000),
      evidenceReviewed: z.boolean().default(false),
    })
    .strict()
    .parse(input);
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
    orgId,
  ]);
  const v = (
    await db.query(
      "SELECT * FROM publisher_verifications WHERE organization_id=$1 FOR UPDATE",
      [orgId],
    )
  ).rows[0];
  requireCondition(v, "Verification request not found.", 404);
  checkRevision(v, b.revision);
  if (b.status === "verified")
    requireCondition(
      v.attachment_id && b.evidenceReviewed,
      "Review the submitted identity evidence before approving.",
    );
  await db.query(
    "UPDATE publisher_verifications SET status=$2,reviewed_by=$3,reviewed_at=now(),revision=revision+1 WHERE organization_id=$1",
    [orgId, b.status, ctx.userId],
  );
  await platformEvent(db, ctx, `publisher-${b.status}`, orgId, b.reason);
  await audit(
    db,
    { ...ctx, orgId },
    "Publisher review completed",
    b.reason,
    "listing",
    orgId,
  );
  if (v.submitted_by)
    await notify(
      db,
      orgId,
      v.submitted_by,
      "Publisher review completed",
      `${b.status}: ${b.reason}`,
      randomUUID(),
    );
  return { id: orgId };
}
export async function reviewListing(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  platformAccess(ctx);
  const b = z
    .object({
      revision: z.number().int().positive(),
      status: z.enum(["approved", "rejected", "unpublished"]),
      reason: z.string().trim().min(10).max(2000),
    })
    .strict()
    .parse(input);
  const l = (await db.query("SELECT * FROM listings WHERE id=$1", [id]))
    .rows[0];
  requireCondition(l, "Listing not found.", 404);
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
    l.organization_id,
  ]);
  const locked = (
    await db.query("SELECT * FROM listings WHERE id=$1 FOR UPDATE", [id])
  ).rows[0];
  checkRevision(locked, b.revision);
  if (b.status === "approved") {
    requireCondition(
      ["pending", "unpublished", "rejected"].includes(locked.status),
      "Submit a draft for review before approval.",
      409,
    );
    const verified = await db.query(
      "SELECT 1 FROM publisher_verifications WHERE organization_id=$1 AND status='verified'",
      [l.organization_id],
    );
    requireCondition(verified.rowCount, "Publisher verification is required.");
    const publisher = await db.query(
      "SELECT 1 FROM users WHERE id=$1 AND NOT disabled",
      [locked.created_by],
    );
    requireCondition(
      publisher.rowCount,
      "Restore the publisher account before approving this listing.",
      409,
    );
    await vacancy(db, l.organization_id, l.unit_id);
    const photo = await db.query(
      "SELECT 1 FROM listing_photos WHERE organization_id=$1 AND listing_id=$2",
      [l.organization_id, id],
    );
    requireCondition(photo.rowCount, "Listing photos are required.");
  }
  await db.query(
    "UPDATE listings SET status=$2,published_at=CASE WHEN $2='approved' THEN now() ELSE NULL END,revision=revision+1,updated_at=now() WHERE id=$1",
    [id, b.status],
  );
  const previousCases = (
    await db.query(
      "SELECT id FROM moderation_cases WHERE organization_id=$1 AND listing_id=$2 AND status<>'resolved'",
      [l.organization_id, id],
    )
  ).rows;
  for (const c of previousCases) {
    await db.query(
      "UPDATE moderation_cases SET status='resolved' WHERE id=$1",
      [c.id],
    );
    await db.query(
      "INSERT INTO moderation_events(id,organization_id,case_id,actor_id,detail) VALUES($1,$2,$3,$4,$5)",
      [
        randomUUID(),
        l.organization_id,
        c.id,
        ctx.userId,
        `${b.status}: ${b.reason}`,
      ],
    );
  }
  if (b.status !== "approved") {
    const caseId = randomUUID();
    await db.query(
      "INSERT INTO moderation_cases(id,organization_id,listing_id,reason,status) VALUES($1,$2,$3,$4,'resolved')",
      [caseId, l.organization_id, id, b.reason],
    );
    await db.query(
      "INSERT INTO moderation_events(id,organization_id,case_id,actor_id,detail) VALUES($1,$2,$3,$4,$5)",
      [
        randomUUID(),
        l.organization_id,
        caseId,
        ctx.userId,
        b.status + ": " + b.reason,
      ],
    );
  }
  await db.query(
    "UPDATE listing_reports SET status='reviewed' WHERE listing_id=$1",
    [id],
  );
  await platformEvent(db, ctx, `listing-${b.status}`, id, b.reason);
  await audit(
    db,
    { ...ctx, orgId: l.organization_id },
    "Listing moderation completed",
    `${b.status}: ${b.reason}`,
    "listing",
    id,
  );
  if (l.created_by)
    await notify(
      db,
      l.organization_id,
      l.created_by,
      "Listing review completed",
      `${l.title}: ${b.status}. ${b.reason}`,
      randomUUID(),
    );
  return { id };
}
export async function appealCase(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  const b = z
    .object({ reason: z.string().trim().min(10).max(3000) })
    .strict()
    .parse(input);
  const row = (
    await db.query(
      "SELECT * FROM moderation_cases WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  requireCondition(row, "Review case not found.", 404);
  await privateListing(db, ctx, row.listing_id);
  requireCondition(
    row.status === "resolved",
    "This case already has an open review.",
    409,
  );
  await db.query(
    "UPDATE moderation_cases SET status='appealed' WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id],
  );
  await db.query(
    "INSERT INTO moderation_events(id,organization_id,case_id,actor_id,detail) VALUES($1,$2,$3,$4,$5)",
    [randomUUID(), ctx.orgId, id, ctx.userId, "Appeal: " + b.reason],
  );
  await audit(
    db,
    ctx,
    "Listing appeal submitted",
    "Listing stays unpublished until reviewed",
    "listing",
    row.listing_id,
  );
  return { id };
}
export async function suspendPublisher(db: Db, ctx: Context, input: unknown) {
  platformAccess(ctx);
  const b = z
    .object({
      userId: z.uuid(),
      disabled: z.boolean(),
      reason: z.string().trim().min(10).max(2000),
    })
    .strict()
    .parse(input);
  requireCondition(
    b.userId !== ctx.userId,
    "You cannot suspend your own administrator account.",
  );
  const user = (
    await db.query("SELECT id,platform_admin FROM users WHERE id=$1", [
      b.userId,
    ])
  ).rows[0];
  requireCondition(
    user && !user.platform_admin,
    "This action only manages non-administrator accounts.",
    403,
  );
  await db.query("UPDATE users SET disabled=$2 WHERE id=$1", [
    b.userId,
    b.disabled,
  ]);
  if (b.disabled)
    await db.query("DELETE FROM sessions WHERE user_id=$1", [b.userId]);
  await platformEvent(
    db,
    ctx,
    b.disabled ? "account-suspended" : "account-restored",
    b.userId,
    b.reason,
  );
  return { id: b.userId };
}
