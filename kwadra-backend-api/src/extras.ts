import type { Db } from "./db.js";
import type { Context } from "./auth.js";
import { requireCondition } from "./errors.js";
import { centavos } from "./contracts.js";

export async function operationsSnapshot(db: Db, ctx: Context) {
  requireCondition(
    ctx.role !== "tenant",
    "Use your tenant portal for your own records.",
    403,
  );
  const properties = (
    await db.query(
      `SELECT id FROM properties p WHERE organization_id=$1 AND ($2::boolean OR EXISTS(SELECT 1 FROM property_assignments a WHERE a.organization_id=p.organization_id AND a.property_id=p.id AND a.user_id=$3))`,
      [ctx.orgId, ctx.allProperties, ctx.userId],
    )
  ).rows.map((p) => p.id);
  const units = (
    await db.query(
      "SELECT id FROM units WHERE organization_id=$1 AND property_id=ANY($2::uuid[])",
      [ctx.orgId, properties],
    )
  ).rows.map((u) => u.id);
  const leases = (
    await db.query(
      "SELECT id FROM leases WHERE organization_id=$1 AND unit_id=ANY($2::uuid[])",
      [ctx.orgId, units],
    )
  ).rows.map((l) => l.id);
  const tickets = (
    await db.query(
      "SELECT id FROM maintenance_tickets WHERE organization_id=$1 AND unit_id=ANY($2::uuid[])",
      [ctx.orgId, units],
    )
  ).rows.map((t) => t.id);
  const meters = (
    await db.query(
      'SELECT id,unit_id AS "unitId",kind,label,rate_centavos AS "rateCentavos",revision FROM utility_meters WHERE organization_id=$1 AND unit_id=ANY($2::uuid[]) ORDER BY label',
      [ctx.orgId, units],
    )
  ).rows;
  const readings = (
    await db.query(
      'SELECT id,meter_id AS "meterId",read_on AS "readOn",value,revision,invoice_id AS "invoiceId",correction_reason AS "correctionReason" FROM utility_readings WHERE organization_id=$1 AND meter_id=ANY($2::uuid[]) ORDER BY read_on DESC',
      [ctx.orgId, meters.map((m) => m.id)],
    )
  ).rows;
  const documents = (
    await db.query(
      `SELECT a.id,a.filename,a.media_type AS "mediaType",d.lease_id AS "leaseId",NULL::uuid AS "ticketId" FROM attachments a JOIN lease_documents d ON d.organization_id=a.organization_id AND d.attachment_id=a.id WHERE a.organization_id=$1 AND d.lease_id=ANY($2::uuid[])
    UNION ALL SELECT a.id,a.filename,a.media_type,NULL::uuid,d.ticket_id FROM attachments a JOIN ticket_attachments d ON d.organization_id=a.organization_id AND d.attachment_id=a.id WHERE a.organization_id=$1 AND d.ticket_id=ANY($3::uuid[])`,
      [ctx.orgId, leases, tickets],
    )
  ).rows;
  const comments = (
    await db.query(
      'SELECT c.id,c.ticket_id AS "ticketId",c.body,u.name,c.created_at AS created FROM maintenance_comments c JOIN users u ON u.id=c.actor_id WHERE c.organization_id=$1 AND c.ticket_id=ANY($2::uuid[]) ORDER BY c.created_at',
      [ctx.orgId, tickets],
    )
  ).rows;
  const announcements = (
    await db.query(
      'SELECT id,property_id AS "propertyId",title,body,published_at AS published FROM announcements WHERE organization_id=$1 AND property_id=ANY($2::uuid[]) ORDER BY published_at DESC',
      [ctx.orgId, properties],
    )
  ).rows;
  const moveOuts = (
    await db.query(
      'SELECT id,lease_id AS "leaseId",requested_on AS "requestedOn",scheduled_on AS "scheduledOn",completed_on AS "completedOn",notes,status,checklist,revision FROM move_outs WHERE organization_id=$1 AND lease_id=ANY($2::uuid[])',
      [ctx.orgId, leases],
    )
  ).rows;
  const listings = (
    await db.query(
      `SELECT l.id,l.unit_id AS "unitId",l.title,l.description,l.location_label AS "locationLabel",l.location_precision AS "locationPrecision",l.latitude,l.longitude,
    l.advertised_rent AS rent,l.move_in_cost AS "moveInCost",l.house_rules AS "houseRules",l.contact_policy AS "contactPolicy",l.public_phone AS "publicPhone",l.public_email AS "publicEmail",l.status,l.revision,
    coalesce((SELECT json_agg(a.amenity_id) FROM listing_amenities a WHERE a.organization_id=l.organization_id AND a.listing_id=l.id),'[]') AS "amenityIds",
    coalesce((SELECT json_agg(p.attachment_id ORDER BY p.position) FROM listing_photos p WHERE p.organization_id=l.organization_id AND p.listing_id=l.id),'[]') AS photos
    FROM listings l WHERE l.organization_id=$1 AND l.unit_id=ANY($2::uuid[]) ORDER BY updated_at DESC`,
      [ctx.orgId, units],
    )
  ).rows.map((l) => ({
    ...l,
    rent: centavos(l.rent),
    moveInCost: centavos(l.moveInCost),
  }));
  const listingIds = listings.map((l) => l.id);
  const inquiries = (
    await db.query(
      'SELECT id,listing_id AS "listingId",name,email,phone,message,status,revision,converted_tenant_id AS "convertedTenantId",created_at AS created FROM inquiries WHERE organization_id=$1 AND listing_id=ANY($2::uuid[]) ORDER BY created_at DESC',
      [ctx.orgId, listingIds],
    )
  ).rows;
  const inquiryIds = inquiries.map((i) => i.id);
  const messages = (
    await db.query(
      'SELECT id,inquiry_id AS "inquiryId",sender,body,created_at AS created FROM inquiry_messages WHERE organization_id=$1 AND inquiry_id=ANY($2::uuid[]) ORDER BY created_at',
      [ctx.orgId, inquiryIds],
    )
  ).rows;
  const viewings = (
    await db.query(
      'SELECT id,inquiry_id AS "inquiryId",scheduled_at AS "scheduledAt",status,revision FROM viewings WHERE organization_id=$1 AND inquiry_id=ANY($2::uuid[]) ORDER BY scheduled_at',
      [ctx.orgId, inquiryIds],
    )
  ).rows;
  const cases = (
    await db.query(
      'SELECT id,listing_id AS "listingId",reason,status FROM moderation_cases WHERE organization_id=$1 AND listing_id=ANY($2::uuid[]) ORDER BY created_at DESC',
      [ctx.orgId, listingIds],
    )
  ).rows;
  const verification =
    (
      await db.query(
        'SELECT status,notes,revision,reviewed_at AS "reviewedAt" FROM publisher_verifications WHERE organization_id=$1',
        [ctx.orgId],
      )
    ).rows[0] ?? null;
  const amenities = (
    await db.query("SELECT id,name FROM amenities ORDER BY name")
  ).rows;
  const assignments = (
    await db.query(
      `SELECT m.user_id AS id,u.name,m.role,m.all_properties AS "allProperties",
    coalesce((SELECT json_agg(a.property_id) FROM property_assignments a WHERE a.organization_id=m.organization_id AND a.user_id=m.user_id),'[]') AS "propertyIds"
    FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.organization_id=$1 AND m.active AND m.role IN ('owner','admin','staff') AND (m.all_properties OR m.role IN ('owner','admin') OR EXISTS(SELECT 1 FROM property_assignments a WHERE a.organization_id=m.organization_id AND a.user_id=m.user_id AND a.property_id=ANY($2::uuid[])))`,
      [ctx.orgId, properties],
    )
  ).rows;
  const ticketDetails = (
    await db.query(
      'SELECT id,assigned_to AS "assignedTo",acknowledged_at AS "acknowledgedAt",closed_at AS "closedAt",revision FROM maintenance_tickets WHERE organization_id=$1 AND id=ANY($2::uuid[])',
      [ctx.orgId, tickets],
    )
  ).rows;
  return {
    meters,
    readings,
    documents,
    comments,
    announcements,
    moveOuts,
    listings,
    inquiries,
    messages,
    viewings,
    cases,
    verification,
    amenities,
    assignments,
    ticketDetails,
  };
}
