import { randomUUID } from "node:crypto";
import sharp from "sharp";
import { z } from "zod";
import type { Db } from "./db.js";
import { canManage, canWrite, unitAccess, type Context } from "./auth.js";
import { leaseAccess, ticketAccess } from "./access.js";
import { ApiError, requireCondition } from "./errors.js";
import { audit } from "./operations.js";

export async function storeFile(
  db: Db,
  ctx: Context,
  input: unknown,
  purpose: "lease" | "maintenance" | "listing" | "verification",
) {
  const b = z
    .object({
      filename: z.string().trim().min(1).max(120),
      base64: z.string().max(2_796_204),
      mediaType: z.enum(["application/pdf", "image/png", "image/jpeg"]),
    })
    .strict()
    .parse(input);
  requireCondition(
    /^[A-Za-z0-9+/]*={0,2}$/.test(b.base64) && b.base64.length % 4 === 0,
    "The file must be valid base64.",
  );
  let bytes = Buffer.from(b.base64, "base64"),
    mediaType: string = b.mediaType;
  requireCondition(
    bytes.length > 0 && bytes.length <= 2097152,
    "Files must be at most 2 MB.",
  );
  const image = bytes
    .subarray(0, 8)
    .equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
    ? "image/png"
    : bytes[0] === 255 && bytes[1] === 216
      ? "image/jpeg"
      : null;
  if (b.mediaType === "application/pdf") {
    requireCondition(
      !["maintenance", "listing"].includes(purpose),
      "Photos must be PNG or JPEG.",
    );
    requireCondition(
      bytes.subarray(0, 5).toString() === "%PDF-",
      "The file is not a PDF.",
    );
  } else {
    requireCondition(
      image === b.mediaType,
      "The image content does not match its media type.",
    );
    try {
      bytes = await sharp(bytes, { limitInputPixels: 16_000_000 })
        .rotate()
        .resize({
          width: 1600,
          height: 1600,
          fit: "inside",
          withoutEnlargement: true,
        })
        .flatten({ background: "#fff" })
        .jpeg({ quality: 82 })
        .toBuffer();
    } catch {
      throw new ApiError(
        422,
        "This image could not be decoded safely.",
        "INVALID_IMAGE",
      );
    }
    mediaType = "image/jpeg";
  }
  const used = Number(
    (
      await db.query(
        "SELECT coalesce(sum(byte_size),0) AS n FROM attachments WHERE organization_id=$1",
        [ctx.orgId],
      )
    ).rows[0].n,
  );
  requireCondition(
    used + bytes.length <= 52_428_800,
    "This development workspace has reached its 50 MB file limit.",
    409,
  );
  const id = randomUUID(),
    filename = b.filename.replace(/[\r\n/\\"<>]/g, "_");
  await db.query(
    "INSERT INTO attachments(id,organization_id,uploaded_by,storage_key,filename,media_type,byte_size,content,purpose) VALUES($1::uuid,$2,$3,$1::uuid::text,$4,$5,$6,$7,$8)",
    [
      id,
      ctx.orgId,
      ctx.userId,
      filename,
      mediaType,
      bytes.length,
      bytes,
      purpose,
    ],
  );
  return { id, filename, mediaType, byteSize: bytes.length };
}
export async function attachFile(
  db: Db,
  ctx: Context,
  kind: "lease" | "maintenance",
  resourceId: string,
  input: unknown,
) {
  if (kind === "lease") {
    canWrite(ctx);
    await leaseAccess(db, ctx, resourceId);
  } else {
    if (ctx.role !== "tenant") canWrite(ctx);
    await ticketAccess(db, ctx, resourceId);
  }
  const file = await storeFile(db, ctx, input, kind);
  if (kind === "lease")
    await db.query(
      "INSERT INTO lease_documents(organization_id,lease_id,attachment_id) VALUES($1,$2,$3)",
      [ctx.orgId, resourceId, file.id],
    );
  else
    await db.query(
      "INSERT INTO ticket_attachments(organization_id,ticket_id,attachment_id) VALUES($1,$2,$3)",
      [ctx.orgId, resourceId, file.id],
    );
  await audit(db, ctx, "Attachment added", kind, "attachment", file.id);
  return file;
}
export async function readFile(db: Db, ctx: Context, id: string) {
  const file = (
    await db.query(
      "SELECT * FROM attachments WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  if (!file) throw new ApiError(404, "File not found.", "NOT_FOUND");
  const lease = (
    await db.query(
      "SELECT lease_id FROM lease_documents WHERE organization_id=$1 AND attachment_id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  const ticket = (
    await db.query(
      "SELECT ticket_id FROM ticket_attachments WHERE organization_id=$1 AND attachment_id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  if (lease) await leaseAccess(db, ctx, lease.lease_id);
  else if (ticket) await ticketAccess(db, ctx, ticket.ticket_id);
  else if (file.purpose === "verification") canManage(ctx);
  else if (file.purpose === "listing") {
    const listing = (
      await db.query(
        "SELECT l.unit_id FROM listings l JOIN listing_photos p ON p.organization_id=l.organization_id AND p.listing_id=l.id WHERE p.organization_id=$1 AND p.attachment_id=$2",
        [ctx.orgId, id],
      )
    ).rows[0];
    if (!listing) throw new ApiError(404, "File not found.", "NOT_FOUND");
    await unitAccess(db, ctx, listing.unit_id);
  } else throw new ApiError(404, "File not found.", "NOT_FOUND");
  return file;
}
