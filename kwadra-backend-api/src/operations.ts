import { randomUUID, createHash } from "node:crypto";
import type { Request, Response } from "express";
import type pg from "pg";
import { z } from "zod";
import { transaction, type Db } from "./db.js";
import {
  canManage,
  canWrite,
  propertyAccess,
  unitAccess,
  type Context,
} from "./auth.js";
import { ApiError, requireCondition } from "./errors.js";
import {
  propertyInput,
  unitInput,
  tenantInput,
  leaseInput,
  ticketInput,
  profileInput,
  periodInput,
  decimal,
  dueDate,
  manilaToday,
} from "./contracts.js";
import { notify } from "./mail.js";

export function checkRevision(
  existing: { revision: number },
  requested: number,
) {
  if (existing.revision !== requested)
    throw new ApiError(
      409,
      "Someone changed this record. Refresh your workspace and reopen the form.",
      "STALE_RECORD",
    );
}
export async function audit(
  db: Db,
  ctx: Context,
  title: string,
  detail: string,
  kind: string,
  resourceId: string | null,
  propertyId: string | null = null,
) {
  await db.query(
    "INSERT INTO audit_events(id,organization_id,actor_id,property_id,title,detail,kind,resource_type,resource_id) VALUES($1,$2,$3,$4,$5,$6,$7,$7,$8)",
    [
      randomUUID(),
      ctx.orgId,
      ctx.userId,
      propertyId,
      title,
      detail,
      kind,
      resourceId,
    ],
  );
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  if (value !== null && typeof value === "object")
    return (
      "{" +
      Object.keys(value)
        .sort()
        .map(
          (k) =>
            JSON.stringify(k) +
            ":" +
            canonical((value as Record<string, unknown>)[k]),
        )
        .join(",") +
      "}"
    );
  return JSON.stringify(value);
}
export async function write(
  pool: pg.Pool,
  req: Request,
  res: Response,
  operation: string,
  fn: (db: Db, ctx: Context) => Promise<unknown>,
  options: { selfService?: boolean } = {},
) {
  const ctx = req.auth!;
  if (!options.selfService) canWrite(ctx);
  const key = z
    .string()
    .min(8)
    .max(120)
    .regex(/^[a-zA-Z0-9-]+$/)
    .parse(req.header("Idempotency-Key"));
  const hash = createHash("sha256")
    .update(canonical({ operation, path: req.path, body: req.body }))
    .digest("hex");
  const result = await transaction(
    pool,
    async (db) => {
      const membership = (
        await db.query(
          "SELECT * FROM memberships WHERE organization_id=$1 AND user_id=$2 AND active FOR SHARE",
          [ctx.orgId, ctx.userId],
        )
      ).rows[0];
      if (!membership)
        throw new ApiError(
          403,
          "Your organization access was revoked.",
          "FORBIDDEN",
        );
      ctx.role = membership.role;
      ctx.allProperties =
        membership.all_properties ||
        ["owner", "admin"].includes(membership.role);
      if (!options.selfService) canWrite(ctx);
      const existing = (
        await db.query(
          "SELECT * FROM idempotency_keys WHERE organization_id=$1 AND actor_id=$2 AND key=$3",
          [ctx.orgId, ctx.userId, key],
        )
      ).rows[0];
      if (existing) {
        if (existing.payload_hash !== hash || existing.operation !== operation)
          throw new ApiError(
            409,
            "This retry key was already used for a different request.",
            "IDEMPOTENCY_CONFLICT",
          );
        return existing.response;
      }
      const data = await fn(db, ctx);
      const org = (
        await db.query(
          "UPDATE organizations SET revision=revision+1 WHERE id=$1 RETURNING revision",
          [ctx.orgId],
        )
      ).rows[0];
      const response = { data, revision: org.revision };
      await db.query(
        "INSERT INTO idempotency_keys(organization_id,actor_id,key,operation,payload_hash,response) VALUES($1,$2,$3,$4,$5,$6)",
        [ctx.orgId, ctx.userId, key, operation, hash, JSON.stringify(response)],
      );
      return response;
    },
    ctx.orgId,
  );
  res.json(result);
}

export async function saveProperty(
  db: Db,
  ctx: Context,
  input: unknown,
  updateId?: string,
) {
  canManage(ctx);
  const b = propertyInput.parse(input);
  requireCondition(
    !updateId || b.id === updateId,
    "URL and record IDs must match.",
    400,
  );
  const old = updateId ? await propertyAccess(db, ctx, updateId) : null;
  if (old) checkRevision(old, b.revision);
  if (b.archived) {
    const reserved = await db.query(
      `SELECT 1 FROM leases l JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id
      WHERE l.organization_id=$1 AND u.property_id=$2 AND l.status='active' AND l.ends_on>=$3 LIMIT 1`,
      [ctx.orgId, b.id, manilaToday()],
    );
    requireCondition(
      !reserved.rowCount,
      "End current and upcoming leases before archiving this property.",
      409,
    );
  }
  if (old)
    await db.query(
      "UPDATE properties SET name=$3,address=$4,type=$5,image=$6,notes=$7,archived=$8,details=$9,revision=revision+1 WHERE organization_id=$1 AND id=$2",
      [
        ctx.orgId,
        b.id,
        b.name,
        b.address,
        b.type,
        b.image,
        b.notes,
        b.archived,
        JSON.stringify(b.details),
      ],
    );
  else
    await db.query(
      "INSERT INTO properties(id,organization_id,name,address,type,image,notes,archived,details) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)",
      [
        b.id,
        ctx.orgId,
        b.name,
        b.address,
        b.type,
        b.image,
        b.notes,
        b.archived,
        JSON.stringify(b.details),
      ],
    );
  await audit(
    db,
    ctx,
    old
      ? b.archived
        ? "Property archived"
        : "Property updated"
      : "Property added",
    b.name,
    "property",
    b.id,
    b.id,
  );
  return { id: b.id };
}
export async function saveUnit(
  db: Db,
  ctx: Context,
  input: unknown,
  updateId?: string,
) {
  const b = unitInput.parse(input);
  requireCondition(
    !updateId || b.id === updateId,
    "URL and record IDs must match.",
    400,
  );
  const property = await propertyAccess(db, ctx, b.propertyId);
  requireCondition(
    !property.archived,
    "Restore the property before changing its units.",
    409,
  );
  const old = updateId ? await unitAccess(db, ctx, updateId) : null;
  if (old) {
    checkRevision(old, b.revision);
    requireCondition(
      old.property_id === b.propertyId,
      "A unit cannot be moved to another property.",
    );
  }
  if (b.maintenance) {
    const active = await db.query(
      "SELECT 1 FROM leases WHERE organization_id=$1 AND unit_id=$2 AND status='active' AND ends_on>=$3 LIMIT 1",
      [ctx.orgId, b.id, manilaToday()],
    );
    requireCondition(
      !active.rowCount,
      "An occupied or reserved unit cannot be taken out of service.",
      409,
    );
  }
  const tooMany = await db.query(
    `SELECT 1 FROM leases l JOIN lease_participants p ON p.organization_id=l.organization_id AND p.lease_id=l.id
    WHERE l.organization_id=$1 AND l.unit_id=$2 AND l.status='active' AND l.ends_on>=$3
    GROUP BY l.id HAVING count(*)>$4`,
    [ctx.orgId, b.id, manilaToday(), b.capacity],
  );
  requireCondition(
    !tooMany.rowCount,
    "The capacity cannot be reduced below the current or upcoming lease participants.",
    409,
  );
  if (old)
    await db.query(
      "UPDATE units SET code=$3,type=$4,rent=$5,capacity=$6,floor=$7,maintenance=$8,notes=$9,revision=revision+1 WHERE organization_id=$1 AND id=$2",
      [
        ctx.orgId,
        b.id,
        b.code,
        b.type,
        decimal(b.rent),
        b.capacity,
        b.floor,
        b.maintenance,
        b.notes,
      ],
    );
  else
    await db.query(
      "INSERT INTO units(id,organization_id,property_id,code,type,rent,capacity,floor,maintenance,notes) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
      [
        b.id,
        ctx.orgId,
        b.propertyId,
        b.code,
        b.type,
        decimal(b.rent),
        b.capacity,
        b.floor,
        b.maintenance,
        b.notes,
      ],
    );
  await audit(
    db,
    ctx,
    old ? "Unit updated" : "Unit added",
    `${property.name} · ${b.code}`,
    "property",
    b.id,
    b.propertyId,
  );
  return { id: b.id };
}
export async function saveTenant(
  db: Db,
  ctx: Context,
  input: unknown,
  updateId?: string,
) {
  // A tenant may belong to several properties. Restricted staff can view linked
  // profiles but cannot edit organization-wide personal information.
  if (!ctx.allProperties)
    throw new ApiError(
      403,
      "Organization-wide access is required to manage tenant profiles.",
      "FORBIDDEN",
    );
  const b = tenantInput.parse(input);
  requireCondition(
    !updateId || b.id === updateId,
    "URL and record IDs must match.",
    400,
  );
  const old = updateId
    ? (
        await db.query(
          "SELECT * FROM tenants WHERE organization_id=$1 AND id=$2",
          [ctx.orgId, b.id],
        )
      ).rows[0]
    : null;
  if (updateId && !old)
    throw new ApiError(404, "Tenant not found.", "NOT_FOUND");
  if (old) checkRevision(old, b.revision);
  if (b.archived) {
    const active = await db.query(
      `SELECT 1 FROM leases l JOIN lease_participants p ON p.organization_id=l.organization_id AND p.lease_id=l.id
      WHERE l.organization_id=$1 AND p.tenant_id=$2 AND l.status='active' AND l.ends_on>=$3 LIMIT 1`,
      [ctx.orgId, b.id, manilaToday()],
    );
    requireCondition(
      !active.rowCount,
      "End current and upcoming leases before archiving this tenant.",
      409,
    );
  }
  if (old)
    await db.query(
      "UPDATE tenants SET name=$3,email=$4,phone=$5,emergency=$6,archived=$7,revision=revision+1 WHERE organization_id=$1 AND id=$2",
      [
        ctx.orgId,
        b.id,
        b.name,
        b.email.toLowerCase(),
        b.phone,
        b.emergency,
        b.archived,
      ],
    );
  else
    await db.query(
      "INSERT INTO tenants(id,organization_id,name,email,phone,emergency,archived) VALUES($1,$2,$3,$4,$5,$6,$7)",
      [
        b.id,
        ctx.orgId,
        b.name,
        b.email.toLowerCase(),
        b.phone,
        b.emergency,
        b.archived,
      ],
    );
  await audit(
    db,
    ctx,
    old ? (b.archived ? "Tenant archived" : "Tenant updated") : "Tenant added",
    b.name,
    "tenant",
    b.id,
  );
  return { id: b.id };
}
export async function createLease(db: Db, ctx: Context, input: unknown) {
  const b = leaseInput.parse(input),
    unit = await unitAccess(db, ctx, b.unitId),
    property = await propertyAccess(db, ctx, unit.property_id);
  requireCondition(
    !unit.maintenance && !property.archived,
    "This unit is archived or under maintenance.",
    409,
  );
  requireCondition(
    b.end >= b.start,
    "The end date must be on or after the start date.",
  );
  requireCondition(
    new Set(b.tenantIds).size === b.tenantIds.length &&
      b.tenantIds.length <= unit.capacity,
    "Lease participants must be unique and fit the unit capacity.",
  );
  for (const tenantId of b.tenantIds) {
    const tenant = (
      await db.query(
        "SELECT * FROM tenants WHERE organization_id=$1 AND id=$2 AND NOT archived",
        [ctx.orgId, tenantId],
      )
    ).rows[0];
    requireCondition(
      tenant,
      "Choose active tenant profiles from this organization.",
    );
    if (!ctx.allProperties) {
      const linked = await db.query(
        `SELECT 1 FROM lease_participants p JOIN leases l ON l.organization_id=p.organization_id AND l.id=p.lease_id
        JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id JOIN property_assignments a ON a.organization_id=u.organization_id AND a.property_id=u.property_id
        WHERE p.organization_id=$1 AND p.tenant_id=$2 AND a.user_id=$3 LIMIT 1`,
        [ctx.orgId, tenantId, ctx.userId],
      );
      requireCondition(
        linked.rowCount,
        "This tenant is outside your assigned properties.",
        403,
      );
    }
  }
  await db.query(
    "INSERT INTO leases(id,organization_id,unit_id,starts_on,ends_on,rent,deposit_terms,due_day,status) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)",
    [
      b.id,
      ctx.orgId,
      b.unitId,
      b.start,
      b.end,
      decimal(b.rent),
      decimal(b.deposit),
      b.dueDay,
      b.status,
    ],
  );
  for (const [i, tenantId] of b.tenantIds.entries())
    await db.query(
      "INSERT INTO lease_participants(organization_id,lease_id,tenant_id,is_primary) VALUES($1,$2,$3,$4)",
      [ctx.orgId, b.id, tenantId, i === 0],
    );
  await audit(
    db,
    ctx,
    "Lease created",
    `${property.name} · ${unit.code}`,
    "lease",
    b.id,
    unit.property_id,
  );
  return { id: b.id };
}
export async function endLease(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  const b = z
    .object({ revision: z.number().int().positive() })
    .strict()
    .parse(input);
  const lease = (
    await db.query("SELECT * FROM leases WHERE organization_id=$1 AND id=$2", [
      ctx.orgId,
      id,
    ])
  ).rows[0];
  if (!lease) throw new ApiError(404, "Lease not found.", "NOT_FOUND");
  const unit = await unitAccess(db, ctx, lease.unit_id);
  checkRevision(lease, b.revision);
  requireCondition(
    lease.status === "active",
    "This lease has already ended.",
    409,
  );
  const today = manilaToday(),
    status = today < lease.starts_on ? "cancelled" : "ended";
  // The termination day is exclusive. Natural expiry retains the final day.
  await db.query(
    "UPDATE leases SET status=$3,terminated_on=$4,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id, status, today],
  );
  await audit(
    db,
    ctx,
    status === "cancelled" ? "Upcoming lease cancelled" : "Lease ended",
    "Existing rent invoices have been preserved.",
    "lease",
    id,
    unit.property_id,
  );
  return { id };
}
export async function generateInvoices(db: Db, ctx: Context, input: unknown) {
  const { period } = periodInput.parse(input),
    today = manilaToday();
  requireCondition(
    period >= "1900-01" && period <= today.slice(0, 7),
    "Choose the current or an earlier month. Future billing is disabled.",
  );
  const leases = (
    await db.query(
      `SELECT l.*,u.property_id FROM leases l JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id
    WHERE l.organization_id=$1 AND l.status='active' AND l.starts_on<($2::date+interval '1 month') AND l.ends_on>=$2::date
    AND ($3::boolean OR EXISTS(SELECT 1 FROM property_assignments a WHERE a.organization_id=u.organization_id AND a.property_id=u.property_id AND a.user_id=$4))
    AND NOT EXISTS(SELECT 1 FROM invoices i WHERE i.organization_id=l.organization_id AND i.lease_id=l.id AND i.period=$2::date AND i.kind='rent')
    ORDER BY l.id`,
      [ctx.orgId, period + "-01", ctx.allProperties, ctx.userId],
    )
  ).rows;
  let created = 0;
  for (const lease of leases) {
    const sequence = (
      await db.query(
        "UPDATE organizations SET next_invoice_number=next_invoice_number+1 WHERE id=$1 RETURNING next_invoice_number-1 AS n",
        [ctx.orgId],
      )
    ).rows[0].n;
    const id = randomUUID(),
      number = `INV-${period.slice(0, 4)}-${String(sequence).padStart(6, "0")}`;
    await db.query(
      "INSERT INTO invoices(id,organization_id,lease_id,number,period,due_on,amount) VALUES($1,$2,$3,$4,$5,$6,$7)",
      [
        id,
        ctx.orgId,
        lease.id,
        number,
        period + "-01",
        dueDate(period, lease.due_day),
        lease.rent,
      ],
    );
    await db.query(
      "INSERT INTO invoice_items(id,organization_id,invoice_id,description,amount) VALUES($1,$2,$3,$4,$5)",
      [randomUUID(), ctx.orgId, id, `Monthly rent · ${period}`, lease.rent],
    );
    await audit(
      db,
      ctx,
      "Rent invoice generated",
      `${number} · ${period}`,
      "invoice",
      id,
      lease.property_id,
    );
    created++;
  }
  return { created };
}
export async function saveTicket(
  db: Db,
  ctx: Context,
  input: unknown,
  updateId?: string,
) {
  const b = ticketInput.parse(input);
  requireCondition(
    !updateId || b.id === updateId,
    "URL and record IDs must match.",
    400,
  );
  const unit = await unitAccess(db, ctx, b.unitId),
    property = await propertyAccess(db, ctx, unit.property_id);
  const old = updateId
    ? (
        await db.query(
          "SELECT * FROM maintenance_tickets WHERE organization_id=$1 AND id=$2",
          [ctx.orgId, updateId],
        )
      ).rows[0]
    : null;
  if (updateId && !old)
    throw new ApiError(404, "Repair request not found.", "NOT_FOUND");
  if (old) {
    await unitAccess(db, ctx, old.unit_id);
    checkRevision(old, b.revision);
    requireCondition(
      old.unit_id === b.unitId,
      "A repair request cannot be moved to another unit.",
    );
    requireCondition(
      old.status === b.status ||
        (old.status === "Open" && b.status === "In progress") ||
        (old.status === "In progress" && b.status === "Resolved") ||
        (old.status === "Resolved" && b.status === "Open"),
      "Repairs move from Open to In progress to Resolved; resolved requests may be reopened.",
      409,
    );
    requireCondition(
      !old.closed_at || b.status === "Open",
      "This request is closed; reopen it before editing.",
      409,
    );
    await db.query(
      "UPDATE maintenance_tickets SET title=$3,description=$4,category=$5,priority=$6,status=$7,closed_at=CASE WHEN $7='Open' THEN NULL ELSE closed_at END,revision=revision+1 WHERE organization_id=$1 AND id=$2",
      [
        ctx.orgId,
        b.id,
        b.title,
        b.description,
        b.category,
        b.priority,
        b.status,
      ],
    );
  } else {
    requireCondition(
      !property.archived,
      "Restore this property before opening repair requests.",
      409,
    );
    requireCondition(
      b.status === "Open",
      "New repair requests must start as Open.",
    );
    await db.query(
      "INSERT INTO maintenance_tickets(id,organization_id,unit_id,title,description,category,priority,status,reported_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)",
      [
        b.id,
        ctx.orgId,
        b.unitId,
        b.title,
        b.description,
        b.category,
        b.priority,
        b.status,
        ctx.userId,
      ],
    );
  }
  const actor = (
    await db.query("SELECT name FROM users WHERE id=$1", [ctx.userId])
  ).rows[0];
  const detail = `${manilaToday()} · ${old ? (old.status !== b.status ? b.status : "Updated") : "Created"} by ${actor.name}`;
  await db.query(
    "INSERT INTO maintenance_events(id,organization_id,ticket_id,actor_id,detail) VALUES($1,$2,$3,$4,$5)",
    [randomUUID(), ctx.orgId, b.id, ctx.userId, detail],
  );
  await audit(
    db,
    ctx,
    old ? "Repair request updated" : "Repair request opened",
    b.title,
    "maintenance",
    b.id,
    unit.property_id,
  );
  if (old?.reported_by && old.status !== b.status)
    await notify(
      db,
      ctx.orgId,
      old.reported_by,
      "Repair status updated",
      `${b.title}: ${b.status}`,
      `ticket-status:${b.id}:${old.revision + 1}`,
    );
  return { id: b.id };
}
export async function updateProfile(db: Db, ctx: Context, input: unknown) {
  canManage(ctx);
  const b = profileInput.parse(input);
  const org = (
    await db.query("SELECT revision FROM organizations WHERE id=$1", [
      ctx.orgId,
    ])
  ).rows[0];
  checkRevision(org, b.revision);
  // Email is a login identifier. Changing it needs a verified-email workflow.
  const user = (
    await db.query("SELECT email FROM users WHERE id=$1", [ctx.userId])
  ).rows[0];
  requireCondition(
    b.email.toLowerCase() === user.email.toLowerCase(),
    "Changing the login email is not enabled yet.",
  );
  await db.query("UPDATE users SET name=$2 WHERE id=$1", [ctx.userId, b.name]);
  await db.query("UPDATE organizations SET name=$2 WHERE id=$1", [
    ctx.orgId,
    b.organization,
  ]);
  await audit(
    db,
    ctx,
    "Workspace updated",
    b.organization,
    "settings",
    ctx.orgId,
  );
  return { id: ctx.orgId };
}
