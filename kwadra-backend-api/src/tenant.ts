import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { Db } from "./db.js";
import type { Context } from "./auth.js";
import { unitAccess, canWrite } from "./auth.js";
import { leaseAccess, ticketAccess } from "./access.js";
import { audit, checkRevision, endLease } from "./operations.js";
import { requireCondition } from "./errors.js";
import { date, manilaToday, centavos } from "./contracts.js";
import { notify } from "./mail.js";

export async function portal(db: Db, ctx: Context) {
  requireCondition(
    ctx.role === "tenant",
    "This account is not a tenant account.",
    403,
  );
  const leases = (
    await db.query(
      `SELECT l.*,u.code,u.type,p.name AS property_name,p.address,p.details FROM leases l
    JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id JOIN properties p ON p.organization_id=u.organization_id AND p.id=u.property_id
    WHERE l.organization_id=$1 AND l.status<>'draft' AND EXISTS(SELECT 1 FROM lease_participants x JOIN tenants t ON t.organization_id=x.organization_id AND t.id=x.tenant_id
      WHERE x.organization_id=l.organization_id AND x.lease_id=l.id AND t.user_id=$2) ORDER BY l.starts_on DESC`,
      [ctx.orgId, ctx.userId],
    )
  ).rows;
  const ids = leases.map((l) => l.id);
  const invoices = (
    await db.query(
      `SELECT i.*,coalesce((SELECT json_agg(json_build_object('description',x.description,'amount',(x.amount*100)::bigint)) FROM invoice_items x WHERE x.organization_id=i.organization_id AND x.invoice_id=i.id),'[]') AS items
    FROM invoices i WHERE organization_id=$1 AND lease_id=ANY($2::uuid[]) ORDER BY due_on DESC`,
      [ctx.orgId, ids],
    )
  ).rows;
  const tickets = (
    await db.query(
      'SELECT id,unit_id AS "unitId",title,description,category,priority,status,revision,created_at AS created,closed_at AS "closedAt" FROM maintenance_tickets WHERE organization_id=$1 AND reported_by=$2 ORDER BY created_at DESC',
      [ctx.orgId, ctx.userId],
    )
  ).rows;
  const ticketIds = tickets.map((t) => t.id);
  const history = (
    await db.query(
      'SELECT ticket_id AS "ticketId",detail,created_at AS created FROM maintenance_events WHERE organization_id=$1 AND ticket_id=ANY($2::uuid[]) ORDER BY created_at',
      [ctx.orgId, ticketIds],
    )
  ).rows;
  const comments = (
    await db.query(
      'SELECT c.id,c.ticket_id AS "ticketId",u.name,c.body,c.created_at AS created FROM maintenance_comments c JOIN users u ON u.id=c.actor_id WHERE c.organization_id=$1 AND c.ticket_id=ANY($2::uuid[]) ORDER BY c.created_at',
      [ctx.orgId, ticketIds],
    )
  ).rows;
  const documents = (
    await db.query(
      `SELECT a.id,a.filename,a.media_type AS "mediaType",a.byte_size AS "byteSize",d.lease_id AS "leaseId",NULL::uuid AS "ticketId" FROM attachments a
    JOIN lease_documents d ON d.organization_id=a.organization_id AND d.attachment_id=a.id WHERE a.organization_id=$1 AND d.lease_id=ANY($2::uuid[])
    UNION ALL SELECT a.id,a.filename,a.media_type,a.byte_size,NULL::uuid,d.ticket_id FROM attachments a JOIN ticket_attachments d ON d.organization_id=a.organization_id AND d.attachment_id=a.id
    WHERE a.organization_id=$1 AND d.ticket_id=ANY($3::uuid[])`,
      [ctx.orgId, ids, ticketIds],
    )
  ).rows;
  const moveOuts = (
    await db.query(
      'SELECT id,lease_id AS "leaseId",requested_on AS "requestedOn",scheduled_on AS "scheduledOn",completed_on AS "completedOn",status,notes,checklist,revision FROM move_outs WHERE organization_id=$1 AND lease_id=ANY($2::uuid[])',
      [ctx.orgId, ids],
    )
  ).rows;
  const announcements = (
    await db.query(
      `SELECT a.id,a.title,a.body,a.published_at AS published,p.name AS property FROM announcements a JOIN properties p ON p.organization_id=a.organization_id AND p.id=a.property_id
    WHERE a.organization_id=$1 AND a.published_at IS NOT NULL AND EXISTS(SELECT 1 FROM leases l JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id
      WHERE l.organization_id=a.organization_id AND l.id=ANY($2::uuid[]) AND u.property_id=a.property_id
      AND l.occupancy @> (a.published_at AT TIME ZONE 'Asia/Manila')::date) ORDER BY a.published_at DESC`,
      [ctx.orgId, ids],
    )
  ).rows;
  const user = (
    await db.query("SELECT id,name,email FROM users WHERE id=$1", [ctx.userId])
  ).rows[0];
  return {
    user,
    today: manilaToday(),
    leases: leases.map((l) => ({
      id: l.id,
      unitId: l.unit_id,
      unit: l.code,
      property: l.property_name,
      address: l.address,
      start: l.starts_on,
      end: l.ends_on,
      status: l.status,
      rent: centavos(l.rent),
      depositTerms: centavos(l.deposit_terms),
      dueDay: l.due_day,
      contact: l.details?.contact ?? "",
    })),
    invoices: invoices.map((i) => ({
      id: i.id,
      number: i.number,
      leaseId: i.lease_id,
      period: i.period.slice(0, 7),
      due: i.due_on,
      amount: centavos(i.amount),
      kind: i.kind,
      items: i.items,
    })),
    tickets,
    history,
    comments,
    documents,
    moveOuts,
    announcements,
  };
}
export async function tenantTicket(db: Db, ctx: Context, input: unknown) {
  requireCondition(ctx.role === "tenant", "Tenant access required.", 403);
  const b = z
    .object({
      leaseId: z.uuid(),
      title: z.string().trim().min(1).max(160),
      description: z.string().trim().min(1).max(10000),
      category: z.enum([
        "General",
        "Plumbing",
        "Electrical",
        "Appliance",
        "Structural",
        "Other",
      ]),
      priority: z.enum(["Low", "Normal", "Urgent"]),
    })
    .strict()
    .parse(input);
  const lease = await leaseAccess(db, ctx, b.leaseId),
    today = manilaToday();
  requireCondition(
    lease.status === "active" &&
      lease.starts_on <= today &&
      lease.ends_on >= today,
    "Choose your current active tenancy.",
    409,
  );
  const id = randomUUID();
  await db.query(
    "INSERT INTO maintenance_tickets(id,organization_id,unit_id,title,description,category,priority,status,reported_by) VALUES($1,$2,$3,$4,$5,$6,$7,'Open',$8)",
    [
      id,
      ctx.orgId,
      lease.unit_id,
      b.title,
      b.description,
      b.category,
      b.priority,
      ctx.userId,
    ],
  );
  await db.query(
    "INSERT INTO maintenance_events(id,organization_id,ticket_id,actor_id,detail) VALUES($1,$2,$3,$4,$5)",
    [randomUUID(), ctx.orgId, id, ctx.userId, `${today} · Submitted by tenant`],
  );
  const unit = (
    await db.query(
      "SELECT property_id FROM units WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, lease.unit_id],
    )
  ).rows[0];
  await audit(
    db,
    ctx,
    "Tenant repair request opened",
    b.title,
    "maintenance",
    id,
    unit.property_id,
  );
  return { id };
}
export async function commentTicket(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  const b = z
    .object({ body: z.string().trim().min(1).max(3000) })
    .strict()
    .parse(input);
  if (ctx.role !== "tenant") canWrite(ctx);
  const ticket = await ticketAccess(db, ctx, id);
  requireCondition(!ticket.closed_at, "This request is closed.", 409);
  await db.query(
    "INSERT INTO maintenance_comments(id,organization_id,ticket_id,actor_id,body) VALUES($1,$2,$3,$4,$5)",
    [randomUUID(), ctx.orgId, id, ctx.userId, b.body],
  );
  await audit(
    db,
    ctx,
    "Repair comment added",
    "Comment saved",
    "maintenance",
    id,
  );
  return { id };
}
export async function assignTicket(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  canWrite(ctx);
  const b = z
    .object({
      revision: z.number().int().positive(),
      assignedTo: z.uuid().nullable(),
      close: z.boolean().default(false),
    })
    .strict()
    .parse(input);
  const ticket = await ticketAccess(db, ctx, id);
  checkRevision(ticket, b.revision);
  const unit = await unitAccess(db, ctx, ticket.unit_id);
  if (b.assignedTo) {
    const member = await db.query(
      `SELECT 1 FROM memberships m WHERE m.organization_id=$1 AND m.user_id=$2 AND m.active AND m.role IN ('owner','admin','staff')
      AND (m.all_properties OR m.role IN ('owner','admin') OR EXISTS(SELECT 1 FROM property_assignments p WHERE p.organization_id=m.organization_id AND p.user_id=m.user_id AND p.property_id=$3))`,
      [ctx.orgId, b.assignedTo, unit.property_id],
    );
    requireCondition(
      member.rowCount,
      "Assign a staff member with access to this property.",
    );
  }
  requireCondition(
    !b.close || ticket.status === "Resolved",
    "Resolve the request before closing it.",
    409,
  );
  await db.query(
    "UPDATE maintenance_tickets SET assigned_to=$3,acknowledged_at=coalesce(acknowledged_at,now()),closed_at=CASE WHEN $4 THEN now() ELSE closed_at END,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id, b.assignedTo, b.close],
  );
  await db.query(
    "INSERT INTO maintenance_events(id,organization_id,ticket_id,actor_id,detail) VALUES($1,$2,$3,$4,$5)",
    [
      randomUUID(),
      ctx.orgId,
      id,
      ctx.userId,
      `${manilaToday()} · ${b.close ? "Closed" : "Acknowledged and assigned"}`,
    ],
  );
  if (ticket.reported_by)
    await notify(
      db,
      ctx.orgId,
      ticket.reported_by,
      "Repair request updated",
      `${ticket.title}: ${b.close ? "Closed" : "Acknowledged"}`,
      `ticket:${id}:${ticket.revision + 1}`,
    );
  await audit(
    db,
    ctx,
    b.close ? "Repair request closed" : "Repair request assigned",
    ticket.title,
    "maintenance",
    id,
    unit.property_id,
  );
  return { id };
}
export async function requestMoveOut(db: Db, ctx: Context, input: unknown) {
  if (ctx.role !== "tenant") canWrite(ctx);
  const b = z
    .object({
      leaseId: z.uuid(),
      requestedOn: date,
      notes: z.string().max(3000).default(""),
    })
    .strict()
    .parse(input);
  const lease = await leaseAccess(db, ctx, b.leaseId);
  requireCondition(lease.status === "active", "This lease is not active.", 409);
  requireCondition(
    b.requestedOn >= manilaToday() &&
      b.requestedOn >= lease.starts_on &&
      b.requestedOn <= lease.ends_on,
    "Choose a date within the remaining lease term.",
  );
  const id = randomUUID();
  await db.query(
    "INSERT INTO move_outs(id,organization_id,lease_id,requested_on,status,notes,requested_by) VALUES($1,$2,$3,$4,'requested',$5,$6)",
    [id, ctx.orgId, b.leaseId, b.requestedOn, b.notes, ctx.userId],
  );
  await audit(db, ctx, "Move-out requested", b.requestedOn, "lease", b.leaseId);
  return { id };
}
export async function updateMoveOut(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  canWrite(ctx);
  const b = z
    .object({
      revision: z.number().int().positive(),
      status: z.enum(["scheduled", "completed", "cancelled"]),
      scheduledOn: date.optional(),
      notes: z.string().max(3000).default(""),
      checklist: z
        .object({
          keysReturned: z.boolean(),
          inspectionComplete: z.boolean(),
          recordsReviewed: z.boolean(),
        })
        .strict(),
    })
    .strict()
    .parse(input);
  const row = (
    await db.query(
      "SELECT * FROM move_outs WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  requireCondition(row, "Move-out request not found.", 404);
  const lease = await leaseAccess(db, ctx, row.lease_id);
  checkRevision(row, b.revision);
  requireCondition(
    ["requested", "scheduled"].includes(row.status),
    "This request is already closed.",
    409,
  );
  if (b.status === "scheduled")
    requireCondition(
      b.scheduledOn &&
        b.scheduledOn >= manilaToday() &&
        b.scheduledOn <= lease.ends_on,
      "Choose a valid remaining lease date.",
    );
  if (b.status === "completed") {
    requireCondition(
      Object.values(b.checklist).every(Boolean),
      "Complete the nonfinancial checklist first.",
    );
    requireCondition(
      row.scheduled_on && row.scheduled_on <= manilaToday(),
      "Complete the move-out on or after its scheduled date.",
      409,
    );
    await endLease(db, ctx, lease.id, { revision: lease.revision });
  }
  await db.query(
    "UPDATE move_outs SET status=$3,scheduled_on=coalesce($4,scheduled_on),completed_on=CASE WHEN $3='completed' THEN $5::date ELSE NULL END,notes=$6,checklist=$7,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [
      ctx.orgId,
      id,
      b.status,
      b.scheduledOn ?? null,
      manilaToday(),
      b.notes,
      JSON.stringify(b.checklist),
    ],
  );
  await audit(
    db,
    ctx,
    "Move-out updated",
    `${b.status}. Deposit transactions and financial closeout remain disabled.`,
    "lease",
    row.lease_id,
  );
  return { id };
}
