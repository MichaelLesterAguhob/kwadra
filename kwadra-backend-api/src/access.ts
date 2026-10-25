import type { Db } from "./db.js";
import { unitAccess, type Context } from "./auth.js";
import { ApiError } from "./errors.js";

export async function leaseAccess(db: Db, ctx: Context, id: string) {
  const row = (
    await db.query("SELECT * FROM leases WHERE organization_id=$1 AND id=$2", [
      ctx.orgId,
      id,
    ])
  ).rows[0];
  if (!row) throw new ApiError(404, "Lease not found.", "NOT_FOUND");
  if (ctx.role === "tenant") {
    if (row.status === "draft")
      throw new ApiError(404, "Lease not found.", "NOT_FOUND");
    const own = await db.query(
      `SELECT 1 FROM lease_participants p JOIN tenants t ON t.organization_id=p.organization_id AND t.id=p.tenant_id
      WHERE p.organization_id=$1 AND p.lease_id=$2 AND t.user_id=$3`,
      [ctx.orgId, id, ctx.userId],
    );
    if (!own.rowCount) throw new ApiError(404, "Lease not found.", "NOT_FOUND");
  } else await unitAccess(db, ctx, row.unit_id);
  return row;
}
export async function ticketAccess(db: Db, ctx: Context, id: string) {
  const row = (
    await db.query(
      "SELECT * FROM maintenance_tickets WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  if (!row) throw new ApiError(404, "Repair request not found.", "NOT_FOUND");
  if (ctx.role === "tenant") {
    if (row.reported_by !== ctx.userId)
      throw new ApiError(404, "Repair request not found.", "NOT_FOUND");
  } else await unitAccess(db, ctx, row.unit_id);
  return row;
}
