import { randomUUID, randomBytes } from "node:crypto";
import { z } from "zod";
import type { Db } from "./db.js";
import {
  unitAccess,
  canManage,
  canWrite,
  hashToken,
  type Context,
} from "./auth.js";
import { ApiError, requireCondition } from "./errors.js";
import { audit, checkRevision } from "./operations.js";
import { centavos, decimal, manilaToday } from "./contracts.js";
import { storeFile } from "./files.js";
import { notify, queueMail } from "./mail.js";

const cents = z.number().int().min(0).max(99_999_999_999_999);
export const listingInput = z
  .object({
    id: z.uuid(),
    unitId: z.uuid(),
    revision: z.number().int().nonnegative().default(0),
    title: z.string().trim().min(5).max(160),
    description: z.string().trim().min(20).max(8000),
    locationLabel: z.string().trim().min(3).max(200),
    locationPrecision: z.enum(["area", "approximate", "exact"]).default("area"),
    latitude: z.number().min(-90).max(90).nullable().default(null),
    longitude: z.number().min(-180).max(180).nullable().default(null),
    rent: cents.min(1),
    moveInCost: cents,
    houseRules: z.string().max(5000).default(""),
    contactPolicy: z
      .enum(["inquiry_only", "show_contact"])
      .default("inquiry_only"),
    publicPhone: z.string().max(60).default(""),
    publicEmail: z.union([z.literal(""), z.email()]).default(""),
    amenityIds: z.array(z.uuid()).max(30).default([]),
  })
  .strict();

export const publicJoins = `FROM listings l JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id
 JOIN properties p ON p.organization_id=u.organization_id AND p.id=u.property_id
 JOIN publisher_verifications v ON v.organization_id=l.organization_id
 JOIN users publisher ON publisher.id=l.created_by`;
export const eligible = `l.status='approved' AND l.published_at IS NOT NULL AND v.status='verified' AND NOT publisher.disabled
 AND NOT u.maintenance AND NOT p.archived AND NOT EXISTS(SELECT 1 FROM leases occupied WHERE occupied.organization_id=l.organization_id
 AND occupied.unit_id=l.unit_id AND occupied.status='active' AND occupied.ends_on>=(now() AT TIME ZONE 'Asia/Manila')::date)`;
const projection = `l.id,l.title,l.description,l.location_label AS "locationLabel",l.location_precision AS "locationPrecision",
 CASE WHEN l.location_precision='exact' THEN l.latitude WHEN l.location_precision='approximate' THEN round(l.latitude,2) ELSE NULL END AS latitude,
 CASE WHEN l.location_precision='exact' THEN l.longitude WHEN l.location_precision='approximate' THEN round(l.longitude,2) ELSE NULL END AS longitude,
 l.advertised_rent AS rent,l.move_in_cost AS "moveInCost",l.house_rules AS "houseRules",l.published_at AS published,
 l.contact_policy AS "contactPolicy",CASE WHEN l.contact_policy='show_contact' THEN l.public_phone ELSE '' END AS "publicPhone",
 CASE WHEN l.contact_policy='show_contact' THEN l.public_email ELSE '' END AS "publicEmail",u.type,u.capacity,p.image,
 (SELECT coalesce(json_agg(json_build_object('id',a.id,'name',a.name)),'[]') FROM listing_amenities la JOIN amenities a ON a.id=la.amenity_id WHERE la.organization_id=l.organization_id AND la.listing_id=l.id) AS amenities,
 (SELECT coalesce(json_agg(ph.attachment_id ORDER BY ph.position),'[]') FROM listing_photos ph WHERE ph.organization_id=l.organization_id AND ph.listing_id=l.id) AS photos,
 v.reviewed_at AS "publisherReviewedAt"`;
export function publicRecord(row: any) {
  return {
    ...row,
    rent: centavos(row.rent),
    moveInCost: centavos(row.moveInCost),
    latitude: row.latitude === null ? null : Number(row.latitude),
    longitude: row.longitude === null ? null : Number(row.longitude),
  };
}
export async function publicSearch(db: Db, input: unknown) {
  const q = z
    .object({
      q: z.string().trim().max(160).default(""),
      minRent: z.coerce.number().int().min(0).optional(),
      maxRent: z.coerce.number().int().min(0).optional(),
      maxMoveInCost: z.coerce.number().int().min(0).optional(),
      type: z.string().max(60).optional(),
      capacity: z.coerce.number().int().min(1).max(20).optional(),
      amenity: z.uuid().optional(),
      sort: z.enum(["newest", "rent_asc", "rent_desc"]).default("newest"),
      page: z.coerce.number().int().min(1).default(1),
      pageSize: z.coerce.number().int().min(1).max(48).default(12),
    })
    .strict()
    .parse(input);
  const args: unknown[] = [],
    filters: string[] = [eligible];
  const add = (sql: string, v: unknown) => {
    args.push(v);
    filters.push(sql.replace("?", `$${args.length}`));
  };
  if (q.q) add("(l.title||' '||l.location_label) ILIKE ?", "%" + q.q + "%");
  if (q.minRent !== undefined) add("l.advertised_rent>=?", decimal(q.minRent));
  if (q.maxRent !== undefined) add("l.advertised_rent<=?", decimal(q.maxRent));
  if (q.maxMoveInCost !== undefined)
    add("l.move_in_cost<=?", decimal(q.maxMoveInCost));
  if (q.type) add("u.type=?", q.type);
  if (q.capacity) add("u.capacity>=?", q.capacity);
  if (q.amenity)
    add(
      "EXISTS(SELECT 1 FROM listing_amenities a WHERE a.organization_id=l.organization_id AND a.listing_id=l.id AND a.amenity_id=?)",
      q.amenity,
    );
  const where = filters.join(" AND "),
    order = {
      newest: "l.published_at DESC,l.id",
      rent_asc: "l.advertised_rent,l.id",
      rent_desc: "l.advertised_rent DESC,l.id",
    }[q.sort];
  const count = Number(
    (await db.query(`SELECT count(*) AS n ${publicJoins} WHERE ${where}`, args))
      .rows[0].n,
  );
  const rows = (
    await db.query(
      `SELECT ${projection} ${publicJoins} WHERE ${where} ORDER BY ${order} LIMIT $${args.length + 1} OFFSET $${args.length + 2}`,
      [...args, q.pageSize, (q.page - 1) * q.pageSize],
    )
  ).rows;
  return {
    data: rows.map(publicRecord),
    total: count,
    page: q.page,
    pageSize: q.pageSize,
  };
}
export async function publicListing(db: Db, id: string) {
  const row = (
    await db.query(
      `SELECT ${projection} ${publicJoins} WHERE ${eligible} AND l.id=$1`,
      [id],
    )
  ).rows[0];
  if (!row)
    throw new ApiError(
      404,
      "This rental is not currently available.",
      "NOT_FOUND",
    );
  return publicRecord(row);
}
export async function privateListing(db: Db, ctx: Context, id: string) {
  const row = (
    await db.query(
      "SELECT * FROM listings WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  requireCondition(row, "Listing not found.", 404);
  await unitAccess(db, ctx, row.unit_id);
  return row;
}
export async function vacancy(db: Db, orgId: string, unitId: string) {
  const result = await db.query(
    `SELECT 1 FROM units u JOIN properties p ON p.organization_id=u.organization_id AND p.id=u.property_id
    WHERE u.organization_id=$1 AND u.id=$2 AND NOT p.archived AND NOT u.maintenance AND NOT EXISTS(SELECT 1 FROM leases l WHERE l.organization_id=u.organization_id AND l.unit_id=u.id AND l.status='active' AND l.ends_on>=$3)`,
    [orgId, unitId, manilaToday()],
  );
  requireCondition(
    result.rowCount,
    "This unit is occupied, reserved, archived, or under maintenance.",
    409,
  );
}
export async function saveListing(
  db: Db,
  ctx: Context,
  input: unknown,
  updateId?: string,
) {
  canWrite(ctx);
  const b = listingInput.parse(input),
    unit = await unitAccess(db, ctx, b.unitId);
  requireCondition(!updateId || updateId === b.id, "Listing IDs must match.");
  const old = updateId ? await privateListing(db, ctx, updateId) : null;
  if (old) {
    checkRevision(old, b.revision);
    requireCondition(
      old.unit_id === b.unitId,
      "A listing cannot be moved to another unit.",
    );
  }
  if (b.contactPolicy === "show_contact")
    requireCondition(
      b.publicPhone || b.publicEmail,
      "Add a public contact or use inquiries only.",
    );
  if (b.locationPrecision !== "area")
    requireCondition(
      b.latitude !== null && b.longitude !== null,
      "Coordinates are required for this location precision.",
    );
  requireCondition(
    new Set(b.amenityIds).size === b.amenityIds.length,
    "Amenities must be unique.",
  );
  if (old)
    await db.query(
      `UPDATE listings SET title=$3,description=$4,location_label=$5,location_precision=$6,latitude=$7,longitude=$8,advertised_rent=$9,move_in_cost=$10,
    house_rules=$11,contact_policy=$12,public_phone=$13,public_email=$14,status='draft',published_at=NULL,revision=revision+1,updated_at=now() WHERE organization_id=$1 AND id=$2`,
      [
        ctx.orgId,
        b.id,
        b.title,
        b.description,
        b.locationLabel,
        b.locationPrecision,
        b.latitude,
        b.longitude,
        decimal(b.rent),
        decimal(b.moveInCost),
        b.houseRules,
        b.contactPolicy,
        b.publicPhone,
        b.publicEmail,
      ],
    );
  else
    await db.query(
      `INSERT INTO listings(id,organization_id,unit_id,title,description,location_label,location_precision,latitude,longitude,advertised_rent,move_in_cost,house_rules,contact_policy,public_phone,public_email,status,created_by)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,'draft',$16)`,
      [
        b.id,
        ctx.orgId,
        b.unitId,
        b.title,
        b.description,
        b.locationLabel,
        b.locationPrecision,
        b.latitude,
        b.longitude,
        decimal(b.rent),
        decimal(b.moveInCost),
        b.houseRules,
        b.contactPolicy,
        b.publicPhone,
        b.publicEmail,
        ctx.userId,
      ],
    );
  await db.query(
    "DELETE FROM listing_amenities WHERE organization_id=$1 AND listing_id=$2",
    [ctx.orgId, b.id],
  );
  for (const a of b.amenityIds)
    await db.query(
      "INSERT INTO listing_amenities(organization_id,listing_id,amenity_id) VALUES($1,$2,$3)",
      [ctx.orgId, b.id, a],
    );
  await audit(
    db,
    ctx,
    old ? "Listing updated; review required" : "Listing drafted",
    b.title,
    "listing",
    b.id,
    unit.property_id,
  );
  return { id: b.id };
}
export async function addListingPhoto(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  canWrite(ctx);
  const listing = await privateListing(db, ctx, id);
  const count = Number(
    (
      await db.query(
        "SELECT count(*) AS n FROM listing_photos WHERE organization_id=$1 AND listing_id=$2",
        [ctx.orgId, id],
      )
    ).rows[0].n,
  );
  requireCondition(count < 8, "A listing can have up to eight photos.");
  const file = await storeFile(db, ctx, input, "listing");
  await db.query(
    "INSERT INTO listing_photos(organization_id,listing_id,attachment_id,position) VALUES($1,$2,$3,$4)",
    [ctx.orgId, id, file.id, count],
  );
  await db.query(
    "UPDATE listings SET status='draft',published_at=NULL,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id],
  );
  await audit(
    db,
    ctx,
    "Listing photo added; review required",
    listing.title,
    "listing",
    id,
  );
  return file;
}
export async function submitListing(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  const b = z
      .object({
        revision: z.number().int().positive(),
        action: z.enum(["submit", "unpublish"]),
      })
      .strict()
      .parse(input),
    l = await privateListing(db, ctx, id);
  checkRevision(l, b.revision);
  if (b.action === "submit") {
    await vacancy(db, ctx.orgId, l.unit_id);
    const v = (
      await db.query(
        "SELECT 1 FROM publisher_verifications WHERE organization_id=$1 AND status='verified'",
        [ctx.orgId],
      )
    ).rowCount;
    requireCondition(
      v,
      "Complete publisher verification before submitting a listing.",
      409,
    );
    const photo = await db.query(
      "SELECT 1 FROM listing_photos WHERE organization_id=$1 AND listing_id=$2",
      [ctx.orgId, id],
    );
    requireCondition(photo.rowCount, "Add at least one listing photo.");
    requireCondition(
      ["draft", "rejected", "unpublished"].includes(l.status),
      "This listing is already submitted or published.",
      409,
    );
  }
  await db.query(
    "UPDATE listings SET status=$3,published_at=NULL,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id, b.action === "submit" ? "pending" : "unpublished"],
  );
  await audit(
    db,
    ctx,
    b.action === "submit"
      ? "Listing submitted for review"
      : "Listing unpublished",
    l.title,
    "listing",
    id,
  );
  return { id };
}
export async function requestVerification(
  db: Db,
  ctx: Context,
  input: unknown,
) {
  canManage(ctx);
  const b = z
    .object({ file: z.unknown(), notes: z.string().trim().min(10).max(2000) })
    .strict()
    .parse(input);
  const old = (
    await db.query(
      "SELECT * FROM publisher_verifications WHERE organization_id=$1",
      [ctx.orgId],
    )
  ).rows[0];
  requireCondition(
    old?.status !== "pending",
    "A verification request is already pending.",
    409,
  );
  const file = await storeFile(db, ctx, b.file, "verification");
  await db.query(
    `INSERT INTO publisher_verifications(organization_id,status,notes,attachment_id,submitted_by) VALUES($1,'pending',$2,$3,$4)
    ON CONFLICT(organization_id) DO UPDATE SET status='pending',notes=excluded.notes,attachment_id=excluded.attachment_id,submitted_by=excluded.submitted_by,reviewed_at=NULL,reviewed_by=NULL,revision=publisher_verifications.revision+1`,
    [ctx.orgId, b.notes, file.id, ctx.userId],
  );
  await audit(
    db,
    ctx,
    "Publisher review requested",
    "Private verification evidence uploaded",
    "listing",
    ctx.orgId,
  );
  return { message: "Verification evidence submitted." };
}

export async function ownerRecipients(
  db: Db,
  orgId: string,
  propertyId: string,
  title: string,
  body: string,
  key: string,
) {
  const users = (
    await db.query(
      `SELECT user_id FROM memberships m WHERE organization_id=$1 AND active AND role IN ('owner','admin','staff')
    AND (role IN ('owner','admin') OR all_properties OR EXISTS(SELECT 1 FROM property_assignments a WHERE a.organization_id=m.organization_id AND a.user_id=m.user_id AND a.property_id=$2))`,
      [orgId, propertyId],
    )
  ).rows;
  for (const u of users) await notify(db, orgId, u.user_id, title, body, key);
}
export function viewingTime(value: string) {
  const time = z.iso.datetime({ offset: true }).parse(value),
    n = Date.parse(time) - Date.now();
  requireCondition(
    n >= 0 && n <= 90 * 86400000,
    "Choose a future viewing within 90 days.",
  );
  return time;
}
export async function createInquiry(
  db: Db,
  id: string,
  input: unknown,
  seekerId?: string,
) {
  const b = z
    .object({
      name: z.string().trim().min(1).max(120),
      email: z.email().max(254),
      phone: z.string().max(60).default(""),
      message: z.string().trim().min(10).max(3000),
      viewingAt: z.string().optional(),
      website: z.string().max(0).optional(),
    })
    .strict()
    .parse(input);
  await publicListing(db, id);
  const l = (
    await db.query(
      "SELECT l.organization_id,u.property_id FROM listings l JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id WHERE l.id=$1",
      [id],
    )
  ).rows[0];
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
    l.organization_id,
  ]);
  await publicListing(db, id); // recheck vacancy after obtaining the write lock
  const inquiryId = randomUUID(),
    token = seekerId ? null : randomBytes(32).toString("hex");
  await db.query(
    "INSERT INTO inquiries(id,organization_id,listing_id,name,email,phone,message,status,tracking_hash,tracking_expires_at,seeker_id) VALUES($1,$2,$3,$4,$5,$6,$7,'new',$8,CASE WHEN $8::text IS NULL THEN NULL ELSE now()+interval '30 days' END,$9)",
    [
      inquiryId,
      l.organization_id,
      id,
      b.name,
      b.email.toLowerCase(),
      b.phone,
      b.message,
      token ? hashToken(token) : null,
      seekerId ?? null,
    ],
  );
  await db.query(
    "INSERT INTO inquiry_messages(id,organization_id,inquiry_id,sender,body) VALUES($1,$2,$3,'seeker',$4)",
    [randomUUID(), l.organization_id, inquiryId, b.message],
  );
  if (b.viewingAt)
    await db.query(
      "INSERT INTO viewings(id,organization_id,inquiry_id,scheduled_at,status) VALUES($1,$2,$3,$4,'requested')",
      [randomUUID(), l.organization_id, inquiryId, viewingTime(b.viewingAt)],
    );
  await ownerRecipients(
    db,
    l.organization_id,
    l.property_id,
    "New rental inquiry",
    `${b.name} sent an inquiry. View it in Kwadra.`,
    `inquiry:${inquiryId}`,
  );
  await queueMail(
    db,
    l.organization_id,
    null,
    b.email,
    "Your Kwadra inquiry",
    seekerId
      ? "Your inquiry was received. Open Messages in the Kwadra app to view replies and viewing requests. A viewing is only booked after confirmation."
      : `Your inquiry was received. A viewing is only booked after confirmation.\nTrack your inquiry: /marketplace/track/${inquiryId}#${token}\nThis private link expires in 30 days.`,
    inquiryId,
  );
  return {
    id: inquiryId,
    ...(token ? { trackingToken: token } : {}),
    message: "Inquiry sent. Requested viewings are not confirmed bookings.",
  };
}
export async function trackedInquiry(db: Db, id: string, token: string) {
  requireCondition(
    /^[a-f0-9]{64}$/.test(token),
    "Use your private inquiry link.",
    404,
  );
  const row = (
    await db.query(
      "SELECT i.*,l.title FROM inquiries i JOIN listings l ON l.organization_id=i.organization_id AND l.id=i.listing_id WHERE i.id=$1 AND i.tracking_hash=$2 AND i.tracking_expires_at>now() AND i.seeker_id IS NULL",
      [id, hashToken(token)],
    )
  ).rows[0];
  requireCondition(row, "Inquiry not found or private link expired.", 404);
  return row;
}
export async function inquiryView(db: Db, id: string, token: string) {
  const i = await trackedInquiry(db, id, token);
  return conversationView(db, i);
}
export async function conversationView(db: Db, i: any) {
  const id = i.id;
  const messages = (
    await db.query(
      "SELECT id,sender,body,created_at AS created FROM inquiry_messages WHERE organization_id=$1 AND inquiry_id=$2 ORDER BY created_at,id",
      [i.organization_id, id],
    )
  ).rows;
  const viewings = (
    await db.query(
      'SELECT id,scheduled_at AS "scheduledAt",status,revision FROM viewings WHERE organization_id=$1 AND inquiry_id=$2 ORDER BY scheduled_at',
      [i.organization_id, id],
    )
  ).rows;
  return { id: i.id, title: i.title, status: i.status, messages, viewings };
}
export async function privateInquiry(db: Db, ctx: Context, id: string) {
  const row = (
    await db.query(
      "SELECT * FROM inquiries WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  requireCondition(row, "Inquiry not found.", 404);
  await privateListing(db, ctx, row.listing_id);
  return row;
}
export async function replyInquiry(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  const b = z
      .object({
        revision: z.number().int().positive(),
        message: z.string().trim().min(1).max(3000),
        close: z.boolean().default(false),
      })
      .strict()
      .parse(input),
    row = await privateInquiry(db, ctx, id);
  checkRevision(row, b.revision);
  requireCondition(row.status !== "closed", "This inquiry is closed.", 409);
  const messageId = randomUUID();
  await db.query(
    "INSERT INTO inquiry_messages(id,organization_id,inquiry_id,sender,actor_id,body) VALUES($1,$2,$3,'landlord',$4,$5)",
    [messageId, ctx.orgId, id, ctx.userId, b.message],
  );
  await db.query(
    "UPDATE inquiries SET status=$3,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id, b.close ? "closed" : "contacted"],
  );
  if (row.seeker_id)
    await notify(
      db,
      null,
      row.seeker_id,
      "Your rental inquiry has a reply",
      "A landlord replied. Open Messages in Kwadra to read it.",
      messageId,
      false,
      id,
    );
  else
    await queueMail(
      db,
      ctx.orgId,
      null,
      row.email,
      "Your rental inquiry has a reply",
      "A landlord replied to your inquiry. Use your original private tracking link to read it.",
      messageId,
    );
  await audit(
    db,
    ctx,
    "Inquiry replied to",
    b.close ? "Conversation closed" : "Reply saved",
    "inquiry",
    id,
  );
  return { id };
}
export async function seekerMessage(
  db: Db,
  id: string,
  token: string,
  input: unknown,
) {
  return appendSeekerMessage(db, await trackedInquiry(db, id, token), input);
}
export async function appendSeekerMessage(db: Db, row: any, input: unknown) {
  const b = z
    .object({ message: z.string().trim().min(1).max(3000) })
    .strict()
    .parse(input);
  const id = row.id;
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
    row.organization_id,
  ]);
  row = (await db.query("SELECT * FROM inquiries WHERE id=$1", [id])).rows[0];
  requireCondition(row.status !== "closed", "This inquiry is closed.", 409);
  const messageId = randomUUID();
  await db.query(
    "INSERT INTO inquiry_messages(id,organization_id,inquiry_id,sender,body,actor_id) VALUES($1,$2,$3,'seeker',$4,$5)",
    [messageId, row.organization_id, id, b.message, row.seeker_id],
  );
  const listing = (
    await db.query(
      "SELECT u.property_id FROM listings l JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id WHERE l.id=$1",
      [row.listing_id],
    )
  ).rows[0];
  await ownerRecipients(
    db,
    row.organization_id,
    listing.property_id,
    "Rental inquiry reply",
    "A seeker replied. Open Inquiries in Kwadra.",
    messageId,
  );
  return { id: messageId };
}
export async function updateViewing(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  const b = z
    .object({
      revision: z.number().int().positive(),
      status: z.enum([
        "proposed",
        "confirmed",
        "declined",
        "completed",
        "cancelled",
      ]),
      scheduledAt: z.string().optional(),
    })
    .strict()
    .parse(input);
  const row = (
    await db.query(
      "SELECT * FROM viewings WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  requireCondition(row, "Viewing not found.", 404);
  const inquiry = await privateInquiry(db, ctx, row.inquiry_id);
  checkRevision(row, b.revision);
  requireCondition(
    ["requested", "proposed", "confirmed"].includes(row.status),
    "This viewing is already closed.",
    409,
  );
  if (b.status === "completed")
    requireCondition(
      row.status === "confirmed" &&
        new Date(row.scheduled_at).getTime() <= Date.now(),
      "Only a confirmed past viewing can be completed.",
    );
  if (b.status === "proposed")
    requireCondition(b.scheduledAt, "Propose a new viewing time.");
  if (b.status === "confirmed")
    requireCondition(
      !b.scheduledAt,
      "Use a proposal when changing the viewing time.",
    );
  const time = b.scheduledAt ? viewingTime(b.scheduledAt) : row.scheduled_at;
  await db.query(
    "UPDATE viewings SET status=$3,scheduled_at=$4,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id, b.status, time],
  );
  if (inquiry.seeker_id)
    await notify(
      db,
      null,
      inquiry.seeker_id,
      "Viewing update",
      `Your viewing is ${b.status}. Open Messages in Kwadra for details.`,
      `viewing:${id}:${row.revision + 1}`,
      false,
      inquiry.id,
    );
  else
    await queueMail(
      db,
      ctx.orgId,
      null,
      inquiry.email,
      "Viewing update",
      `Your viewing is ${b.status}. Use your private inquiry link for details.`,
      `viewing:${id}:${row.revision + 1}`,
    );
  await audit(db, ctx, "Viewing updated", b.status, "inquiry", row.inquiry_id);
  return { id };
}
export async function seekerViewing(
  db: Db,
  inquiryId: string,
  token: string,
  input: unknown,
) {
  return actOnSeekerViewing(
    db,
    await trackedInquiry(db, inquiryId, token),
    input,
  );
}
export async function actOnSeekerViewing(db: Db, row: any, input: unknown) {
  const inquiryId = row.id;
  const b = z
    .object({
      id: z.uuid().optional(),
      revision: z.number().int().positive().optional(),
      action: z.enum(["request", "confirm", "cancel"]),
      scheduledAt: z.string().optional(),
    })
    .strict()
    .parse(input);
  await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
    row.organization_id,
  ]);
  row = (await db.query("SELECT * FROM inquiries WHERE id=$1", [inquiryId]))
    .rows[0];
  requireCondition(row.status !== "closed", "This inquiry is closed.", 409);
  if (b.action === "request") {
    requireCondition(b.scheduledAt, "Choose a viewing time.");
    const id = randomUUID();
    await db.query(
      "INSERT INTO viewings(id,organization_id,inquiry_id,scheduled_at,status) VALUES($1,$2,$3,$4,'requested')",
      [id, row.organization_id, inquiryId, viewingTime(b.scheduledAt)],
    );
    await viewingNotice(db, row, id, "request", 1);
    return { id };
  }
  const v = (
    await db.query(
      "SELECT * FROM viewings WHERE organization_id=$1 AND inquiry_id=$2 AND id=$3",
      [row.organization_id, inquiryId, b.id ?? null],
    )
  ).rows[0];
  requireCondition(v, "Viewing not found.", 404);
  checkRevision(v, b.revision ?? 0);
  requireCondition(
    b.action === "confirm"
      ? v.status === "proposed"
      : ["requested", "proposed", "confirmed"].includes(v.status),
    "This viewing cannot make that transition.",
    409,
  );
  if (b.action === "confirm")
    viewingTime(new Date(v.scheduled_at).toISOString());
  await db.query(
    "UPDATE viewings SET status=$3,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [
      row.organization_id,
      v.id,
      b.action === "confirm" ? "confirmed" : "cancelled",
    ],
  );
  await viewingNotice(db, row, v.id, b.action, v.revision + 1);
  return { id: v.id };
}
async function viewingNotice(
  db: Db,
  row: any,
  viewingId: string,
  action: string,
  revision: number,
) {
  const listing = (
    await db.query(
      "SELECT u.property_id FROM listings l JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id WHERE l.id=$1",
      [row.listing_id],
    )
  ).rows[0];
  await ownerRecipients(
    db,
    row.organization_id,
    listing.property_id,
    "Viewing update",
    `A seeker sent a viewing ${action}. Open Inquiries in Kwadra.`,
    `viewing:${viewingId}:${action}:${revision}`,
  );
}
export async function reportListing(db: Db, id: string, input: unknown) {
  const b = z
    .object({
      reason: z.string().trim().min(10).max(2000),
      email: z.union([z.literal(""), z.email()]).default(""),
      website: z.string().max(0).optional(),
    })
    .strict()
    .parse(input);
  await publicListing(db, id);
  const l = (
      await db.query("SELECT organization_id FROM listings WHERE id=$1", [id])
    ).rows[0],
    reportId = randomUUID();
  await db.query(
    "INSERT INTO listing_reports(id,organization_id,listing_id,reason,email) VALUES($1,$2,$3,$4,$5)",
    [reportId, l.organization_id, id, b.reason, b.email],
  );
  return { message: "Report received for review." };
}
