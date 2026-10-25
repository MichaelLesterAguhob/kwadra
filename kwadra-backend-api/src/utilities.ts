import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { Db } from "./db.js";
import { canWrite, unitAccess, propertyAccess, type Context } from "./auth.js";
import { date, decimal, centavos, manilaToday, dueDate } from "./contracts.js";
import { audit, checkRevision } from "./operations.js";
import { requireCondition } from "./errors.js";

const value = z.string().regex(/^\d{1,11}(\.\d{1,4})?$/);
const scaled = (v: string) => {
  const [a, b = ""] = v.split(".");
  return BigInt(a) * 10000n + BigInt(b.padEnd(4, "0"));
};
export async function createMeter(db: Db, ctx: Context, input: unknown) {
  canWrite(ctx);
  const b = z
    .object({
      unitId: z.uuid(),
      kind: z.enum(["water", "electricity", "other"]),
      label: z.string().trim().min(1).max(120),
      rateCentavos: z.number().int().min(1).max(1000000),
    })
    .strict()
    .parse(input);
  const unit = await unitAccess(db, ctx, b.unitId),
    id = randomUUID();
  await db.query(
    "INSERT INTO utility_meters(id,organization_id,unit_id,kind,label,rate_centavos) VALUES($1,$2,$3,$4,$5,$6)",
    [id, ctx.orgId, b.unitId, b.kind, b.label, b.rateCentavos],
  );
  await audit(
    db,
    ctx,
    "Utility meter created",
    b.label,
    "utility",
    id,
    unit.property_id,
  );
  return { id };
}
export async function addReading(db: Db, ctx: Context, input: unknown) {
  canWrite(ctx);
  const b = z
    .object({ meterId: z.uuid(), readOn: date, value })
    .strict()
    .parse(input);
  const meter = (
    await db.query(
      "SELECT * FROM utility_meters WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, b.meterId],
    )
  ).rows[0];
  requireCondition(meter, "Meter not found.", 404);
  await unitAccess(db, ctx, meter.unit_id);
  requireCondition(
    b.readOn <= manilaToday(),
    "Readings cannot be dated in the future.",
  );
  const previous = (
    await db.query(
      "SELECT * FROM utility_readings WHERE organization_id=$1 AND meter_id=$2 ORDER BY read_on DESC LIMIT 1",
      [ctx.orgId, b.meterId],
    )
  ).rows[0];
  requireCondition(
    !previous || b.readOn > previous.read_on,
    "Add readings in date order; use an audited correction for an unbilled reading.",
  );
  requireCondition(
    !previous || scaled(b.value) >= scaled(previous.value),
    "A reading cannot be lower than the preceding reading.",
  );
  const id = randomUUID();
  await db.query(
    "INSERT INTO utility_readings(id,organization_id,meter_id,read_on,value) VALUES($1,$2,$3,$4,$5)",
    [id, ctx.orgId, b.meterId, b.readOn, b.value],
  );
  await audit(
    db,
    ctx,
    "Utility reading added",
    `${meter.label}: ${b.value}`,
    "utility",
    id,
  );
  return { id };
}
export async function correctReading(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  canWrite(ctx);
  const b = z
    .object({
      revision: z.number().int().positive(),
      value,
      reason: z.string().trim().min(10).max(1000),
    })
    .strict()
    .parse(input);
  const row = (
    await db.query(
      "SELECT * FROM utility_readings WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  requireCondition(row, "Reading not found.", 404);
  checkRevision(row, b.revision);
  requireCondition(
    !row.invoice_id,
    "Issued charges cannot be rewritten. Financial adjustments are deferred.",
    409,
  );
  const meter = (
    await db.query(
      "SELECT * FROM utility_meters WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, row.meter_id],
    )
  ).rows[0];
  await unitAccess(db, ctx, meter.unit_id);
  const billedLater = await db.query(
    "SELECT 1 FROM utility_readings WHERE organization_id=$1 AND meter_id=$2 AND read_on>$3 AND invoice_id IS NOT NULL",
    [ctx.orgId, row.meter_id, row.read_on],
  );
  requireCondition(
    !billedLater.rowCount,
    "A later charge already uses this reading. Issued calculations must be preserved.",
    409,
  );
  const neighbors = (
    await db.query(
      "SELECT value,read_on FROM utility_readings WHERE organization_id=$1 AND meter_id=$2 AND id<>$3 ORDER BY read_on",
      [ctx.orgId, row.meter_id, id],
    )
  ).rows;
  requireCondition(
    neighbors.every((n) =>
      n.read_on < row.read_on
        ? scaled(n.value) <= scaled(b.value)
        : scaled(n.value) >= scaled(b.value),
    ),
    "The corrected value must fit between the other readings.",
  );
  await db.query(
    "UPDATE utility_readings SET value=$3,correction_reason=$4,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id, b.value, b.reason],
  );
  await audit(
    db,
    ctx,
    "Utility reading corrected",
    `${row.value} → ${b.value}. ${b.reason}`,
    "utility",
    id,
  );
  return { id };
}
export async function readingPreview(db: Db, ctx: Context, id: string) {
  const r = (
    await db.query(
      "SELECT r.*,m.unit_id,m.rate_centavos,m.label FROM utility_readings r JOIN utility_meters m ON m.organization_id=r.organization_id AND m.id=r.meter_id WHERE r.organization_id=$1 AND r.id=$2",
      [ctx.orgId, id],
    )
  ).rows[0];
  requireCondition(r, "Reading not found.", 404);
  await unitAccess(db, ctx, r.unit_id);
  const prev = (
    await db.query(
      "SELECT * FROM utility_readings WHERE organization_id=$1 AND meter_id=$2 AND read_on<$3 ORDER BY read_on DESC LIMIT 1",
      [ctx.orgId, r.meter_id, r.read_on],
    )
  ).rows[0];
  const consumption = prev ? scaled(r.value) - scaled(prev.value) : 0n;
  const amount = Number(
    (consumption * BigInt(r.rate_centavos) + 5000n) / 10000n,
  );
  const lease = (
    await db.query(
      "SELECT * FROM leases WHERE organization_id=$1 AND unit_id=$2 AND status='active' AND starts_on<=$3 AND ends_on>=$3",
      [ctx.orgId, r.unit_id, r.read_on],
    )
  ).rows[0];
  return {
    reading: r,
    previous: prev?.value ?? null,
    consumption: consumption.toString(),
    scale: 10000,
    amount,
    leaseId: lease?.id ?? null,
    canInvoice: !!prev && amount > 0 && !!lease && !r.invoice_id,
  };
}
export async function utilityInvoice(
  db: Db,
  ctx: Context,
  leaseId: string,
  period: string,
  amount: number,
  description: string,
  source: string,
) {
  requireCondition(
    Number.isSafeInteger(amount) && amount > 0 && amount <= 99_999_999_999_999,
    "Invalid utility amount.",
  );
  const existing = (
    await db.query(
      "SELECT id FROM invoices WHERE organization_id=$1 AND source_key=$2",
      [ctx.orgId, source],
    )
  ).rows[0];
  if (existing) return existing.id;
  const lease = (
    await db.query(
      "SELECT due_day FROM leases WHERE organization_id=$1 AND id=$2",
      [ctx.orgId, leaseId],
    )
  ).rows[0];
  const n = (
    await db.query(
      "UPDATE organizations SET next_invoice_number=next_invoice_number+1 WHERE id=$1 RETURNING next_invoice_number-1 AS n",
      [ctx.orgId],
    )
  ).rows[0].n;
  const id = randomUUID(),
    number = `UTIL-${period.slice(0, 4)}-${String(n).padStart(6, "0")}`;
  await db.query(
    "INSERT INTO invoices(id,organization_id,lease_id,number,period,due_on,amount,kind,source_key) VALUES($1,$2,$3,$4,$5,$6,$7,'utility',$8)",
    [
      id,
      ctx.orgId,
      leaseId,
      number,
      period + "-01",
      dueDate(period, lease.due_day),
      decimal(amount),
      source,
    ],
  );
  await db.query(
    "INSERT INTO invoice_items(id,organization_id,invoice_id,description,amount) VALUES($1,$2,$3,$4,$5)",
    [randomUUID(), ctx.orgId, id, description, decimal(amount)],
  );
  await audit(db, ctx, "Utility invoice issued", number, "invoice", id);
  return id;
}
export async function issueReading(
  db: Db,
  ctx: Context,
  id: string,
  input: unknown,
) {
  const b = z
    .object({
      revision: z.number().int().positive(),
      amount: z.number().int().positive(),
    })
    .strict()
    .parse(input);
  const p = await readingPreview(db, ctx, id);
  checkRevision(p.reading, b.revision);
  requireCondition(
    p.canInvoice,
    "This reading is a baseline, already charged, or has no eligible active lease.",
    409,
  );
  requireCondition(
    p.amount === b.amount,
    "The preview changed. Review the latest calculation.",
    409,
  );
  const invoiceId = await utilityInvoice(
    db,
    ctx,
    p.leaseId,
    p.reading.read_on.slice(0, 7),
    p.amount,
    `${p.reading.label}: ${p.previous} to ${p.reading.value}; rate ${p.reading.rate_centavos} centavos/unit`,
    `reading:${id}`,
  );
  await db.query(
    "UPDATE utility_readings SET invoice_id=$3,revision=revision+1 WHERE organization_id=$1 AND id=$2",
    [ctx.orgId, id, invoiceId],
  );
  return { invoiceId };
}
export async function sharedPreview(db: Db, ctx: Context, input: unknown) {
  const b = z
    .object({
      propertyId: z.uuid(),
      period: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/),
      amount: z.number().int().min(1).max(9999999999),
      description: z.string().trim().min(1).max(160),
    })
    .strict()
    .parse(input);
  await propertyAccess(db, ctx, b.propertyId);
  requireCondition(
    b.period <= manilaToday().slice(0, 7),
    "Future shared charges are disabled.",
  );
  const leases = (
    await db.query(
      `SELECT l.id,u.code FROM leases l JOIN units u ON u.organization_id=l.organization_id AND u.id=l.unit_id
    WHERE l.organization_id=$1 AND u.property_id=$2 AND l.status='active' AND l.starts_on<=($3::date+interval '1 month'-interval '1 day') AND l.ends_on>=$3::date ORDER BY u.code,l.id`,
      [ctx.orgId, b.propertyId, b.period + "-01"],
    )
  ).rows;
  requireCondition(
    leases.length > 0,
    "No eligible active leases overlap this month.",
  );
  requireCondition(
    new Set(leases.map((l) => l.code.toLowerCase())).size === leases.length,
    "This month includes a unit turnover. Review the affected tenancies before issuing a shared bill.",
    409,
  );
  requireCondition(
    b.amount >= leases.length,
    "The amount must allocate at least one centavo to each unit.",
  );
  const base = Math.floor(b.amount / leases.length),
    remainder = b.amount % leases.length;
  return {
    ...b,
    basis:
      "Equal share per occupied unit; remaining centavos go in unit-code order.",
    allocations: leases.map((l, i) => ({
      leaseId: l.id,
      unit: l.code,
      amount: base + (i < remainder ? 1 : 0),
    })),
  };
}
export async function issueShared(db: Db, ctx: Context, input: unknown) {
  canWrite(ctx);
  const b = z
    .object({
      propertyId: z.uuid(),
      period: z.string(),
      amount: z.number(),
      description: z.string(),
      expectedAllocations: z.array(
        z.object({
          leaseId: z.uuid(),
          unit: z.string(),
          amount: z.number().int(),
        }),
      ),
    })
    .strict()
    .parse(input);
  const p = await sharedPreview(db, ctx, {
    propertyId: b.propertyId,
    period: b.period,
    amount: b.amount,
    description: b.description,
  });
  requireCondition(
    JSON.stringify(p.allocations) === JSON.stringify(b.expectedAllocations),
    "Occupancy or allocation changed. Preview again.",
    409,
  );
  const id = randomUUID();
  await db.query(
    "INSERT INTO shared_utility_batches(id,organization_id,property_id,period,description,amount,allocations) VALUES($1,$2,$3,$4,$5,$6,$7)",
    [
      id,
      ctx.orgId,
      b.propertyId,
      b.period + "-01",
      b.description,
      decimal(b.amount),
      JSON.stringify(p.allocations),
    ],
  );
  for (const a of p.allocations)
    await utilityInvoice(
      db,
      ctx,
      a.leaseId,
      b.period,
      a.amount,
      `${b.description} · Equal share (${a.unit})`,
      `shared:${id}:${a.leaseId}`,
    );
  return { id, created: p.allocations.length };
}
