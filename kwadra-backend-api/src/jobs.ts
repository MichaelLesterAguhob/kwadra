import { randomUUID } from "node:crypto";
import type pg from "pg";
import { transaction } from "./db.js";
import { generateInvoices } from "./operations.js";
import { manilaToday } from "./contracts.js";
import { notify, deliverMail } from "./mail.js";
import type { Context } from "./auth.js";
import { config } from "./config.js";

export async function runJobs(pool: pg.Pool, deliver = deliverMail) {
  const organizations = (
    await pool.query(
      `SELECT o.id,(SELECT user_id FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.organization_id=o.id AND m.active AND m.role='owner' AND NOT u.disabled LIMIT 1) AS owner FROM organizations o`,
    )
  ).rows;
  let invoices = 0,
    delivered = 0,
    failed = 0;
  for (const org of organizations)
    if (org.owner)
      await transaction(
        pool,
        async (db) => {
          const ctx: Context = {
            orgId: org.id,
            userId: org.owner,
            role: "owner",
            allProperties: true,
            tokenHash: "",
            csrf: "",
          };
          const generated = await generateInvoices(db, ctx, {
            period: manilaToday().slice(0, 7),
          });
          invoices += generated.created;
          if (generated.created)
            await db.query(
              "UPDATE organizations SET revision=revision+1 WHERE id=$1",
              [org.id],
            );
          const reminders = (
            await db.query(
              `SELECT i.id,i.number,i.due_on,t.user_id FROM invoices i JOIN lease_participants p ON p.organization_id=i.organization_id AND p.lease_id=i.lease_id
      JOIN tenants t ON t.organization_id=p.organization_id AND t.id=p.tenant_id JOIN memberships m ON m.organization_id=t.organization_id AND m.user_id=t.user_id AND m.active
      WHERE i.organization_id=$1 AND t.user_id IS NOT NULL AND i.due_on BETWEEN $2::date AND $2::date+1`,
              [org.id, manilaToday()],
            )
          ).rows;
          for (const r of reminders)
            await notify(
              db,
              org.id,
              r.user_id,
              "Charge due",
              `${r.number} is due ${r.due_on}. Payment tracking is not enabled.`,
              `due:${r.id}:${manilaToday()}`,
            );
        },
        org.id,
      );
  // SKIP LOCKED permits multiple worker processes without duplicate concurrent
  // delivery. Stable message IDs aid SMTP deduplication; external email remains
  // at-least-once when a process crashes after sending but before commit.
  for (
    let i = 0;
    i < 100 &&
    (deliver !== deliverMail ||
      !config.production ||
      process.env.EMAIL_DELIVERY_ENABLED === "true");
    i++
  ) {
    const found = await transaction(pool, async (db) => {
      const row = (
        await db.query(
          "SELECT * FROM delivery_logs WHERE channel='email' AND status<>'delivered' AND attempts<5 AND next_attempt_at<=now() ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED",
        )
      ).rows[0];
      if (!row) return false;
      try {
        await deliver(row);
        await db.query(
          "UPDATE delivery_logs SET status='delivered',attempts=attempts+1,delivered_at=now(),last_error=NULL WHERE id=$1",
          [row.id],
        );
        delivered++;
      } catch {
        await db.query(
          "UPDATE delivery_logs SET status='failed',attempts=attempts+1,last_error='Delivery failed. Check the configured transport.',next_attempt_at=now()+interval '5 minutes' WHERE id=$1",
          [row.id],
        );
        failed++;
      }
      return true;
    });
    if (!found) break;
  }
  await pool.query(
    "DELETE FROM native_session_families WHERE expires_at<now()-interval '1 day'",
  );
  return { invoices, delivered, failed };
}
