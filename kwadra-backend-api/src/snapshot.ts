import type pg from "pg";
import { type Context } from "./auth.js";
import { centavos, manilaToday } from "./contracts.js";

// One repeatable-read snapshot prevents mixing leases and participant/invoice
// lists from different commits. Only authorized records enter client memory.
export async function workspace(pool: pg.Pool, ctx: Context) {
  const db = await pool.connect();
  try {
    await db.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
    const org = (
      await db.query("SELECT * FROM organizations WHERE id=$1", [ctx.orgId])
    ).rows[0];
    const user = (
      await db.query("SELECT name,email FROM users WHERE id=$1", [ctx.userId])
    ).rows[0];
    const properties = (
      await db.query(
        `SELECT p.* FROM properties p WHERE organization_id=$1 AND ($2::boolean OR EXISTS
      (SELECT 1 FROM property_assignments a WHERE a.organization_id=p.organization_id AND a.property_id=p.id AND a.user_id=$3))
      ORDER BY created_at,id`,
        [ctx.orgId, ctx.allProperties, ctx.userId],
      )
    ).rows;
    const propertyIds = properties.map((p) => p.id);
    const units = (
      await db.query(
        "SELECT * FROM units WHERE organization_id=$1 AND property_id=ANY($2::uuid[]) ORDER BY created_at,code,id",
        [ctx.orgId, propertyIds],
      )
    ).rows;
    const unitIds = units.map((u) => u.id);
    const leases = (
      await db.query(
        "SELECT * FROM leases WHERE organization_id=$1 AND unit_id=ANY($2::uuid[]) ORDER BY created_at,id",
        [ctx.orgId, unitIds],
      )
    ).rows;
    const leaseIds = leases.map((l) => l.id);
    const participants = (
      await db.query(
        "SELECT * FROM lease_participants WHERE organization_id=$1 AND lease_id=ANY($2::uuid[]) ORDER BY is_primary DESC,tenant_id",
        [ctx.orgId, leaseIds],
      )
    ).rows;
    const tenantIds = participants.map((p) => p.tenant_id);
    const tenants = (
      await db.query(
        "SELECT * FROM tenants WHERE organization_id=$1 AND ($2::boolean OR id=ANY($3::uuid[])) ORDER BY created_at,id",
        [ctx.orgId, ctx.allProperties, tenantIds],
      )
    ).rows;
    const invoices = (
      await db.query(
        "SELECT * FROM invoices WHERE organization_id=$1 AND lease_id=ANY($2::uuid[]) ORDER BY period,number",
        [ctx.orgId, leaseIds],
      )
    ).rows;
    const tickets = (
      await db.query(
        "SELECT * FROM maintenance_tickets WHERE organization_id=$1 AND unit_id=ANY($2::uuid[]) ORDER BY created_at,id",
        [ctx.orgId, unitIds],
      )
    ).rows;
    const ticketIds = tickets.map((t) => t.id);
    const events = (
      await db.query(
        "SELECT * FROM maintenance_events WHERE organization_id=$1 AND ticket_id=ANY($2::uuid[]) ORDER BY created_at,id",
        [ctx.orgId, ticketIds],
      )
    ).rows;
    const activities = (
      await db.query(
        `SELECT * FROM (SELECT * FROM audit_events WHERE organization_id=$1
      AND ($2::boolean OR property_id=ANY($3::uuid[])) ORDER BY created_at DESC,id DESC LIMIT 1000) a ORDER BY created_at,id`,
        [ctx.orgId, ctx.allProperties, propertyIds],
      )
    ).rows;
    await db.query("COMMIT");
    return {
      version: 1,
      organizationId: ctx.orgId,
      revision: org.revision,
      today: manilaToday(),
      ownerName: user.name,
      ownerEmail: user.email,
      organizationName: org.name,
      permissions: {
        role: ctx.role,
        canWrite: ctx.role !== "viewer",
        canManage: ["owner", "admin"].includes(ctx.role),
        allProperties: ctx.allProperties,
      },
      properties: properties.map((p) => ({
        id: p.id,
        name: p.name,
        address: p.address,
        type: p.type,
        image: p.image,
        notes: p.notes,
        details: p.details,
        archived: p.archived,
        revision: p.revision,
      })),
      units: units.map((u) => ({
        id: u.id,
        propertyId: u.property_id,
        code: u.code,
        type: u.type,
        rent: centavos(u.rent),
        capacity: u.capacity,
        floor: u.floor,
        maintenance: u.maintenance,
        notes: u.notes,
        revision: u.revision,
      })),
      tenants: tenants.map((t) => ({
        id: t.id,
        name: t.name,
        email: t.email,
        phone: t.phone,
        emergency: t.emergency,
        archived: t.archived,
        revision: t.revision,
      })),
      leases: leases.map((l) => ({
        id: l.id,
        unitId: l.unit_id,
        tenantIds: participants
          .filter((p) => p.lease_id === l.id)
          .map((p) => p.tenant_id),
        start: l.starts_on,
        end:
          l.status === "ended" && l.terminated_on <= l.ends_on
            ? l.terminated_on
            : l.ends_on,
        rent: centavos(l.rent),
        deposit: centavos(l.deposit_terms),
        dueDay: l.due_day,
        ended: ["ended", "cancelled"].includes(l.status),
        draft: l.status === "draft",
        cancelled: l.status === "cancelled",
        revision: l.revision,
        // Preserves the inclusive final day when an already-expired lease is closed.
        occupancyEnd: l.status === "ended" ? l.terminated_on : null,
      })),
      invoices: invoices.map((i) => ({
        id: i.id,
        number: i.number,
        leaseId: i.lease_id,
        period: i.period.slice(0, 7),
        due: i.due_on,
        amount: centavos(i.amount),
        kind: i.kind,
      })),
      tickets: tickets.map((t) => ({
        id: t.id,
        unitId: t.unit_id,
        title: t.title,
        description: t.description,
        category: t.category,
        priority: t.priority,
        status: t.status,
        created: t.created_at.toISOString(),
        revision: t.revision,
        history: events
          .filter((e) => e.ticket_id === t.id)
          .map((e) => e.detail),
      })),
      activities: activities.map((a) => ({
        id: a.id,
        title: a.title,
        detail: a.detail,
        kind: a.kind,
        created: a.created_at.toISOString(),
      })),
    };
  } catch (error) {
    await db.query("ROLLBACK");
    throw error;
  } finally {
    db.release();
  }
}
