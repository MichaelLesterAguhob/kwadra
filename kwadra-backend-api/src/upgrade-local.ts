import { readFile } from "node:fs/promises";
import path from "node:path";
import assert from "node:assert/strict";
import { config, root } from "./config.js";
import { createPool, migrate } from "./db.js";
import { localPostgres } from "./local-postgres.js";
// Only the generated local development cluster is eligible for this helper.
// External/production databases use the normal reviewed migration procedure.
async function upgrade() {
  const url = new URL(config.databaseUrl);
  if (
    config.production ||
    url.hostname !== "127.0.0.1" ||
    url.port !== "55432" ||
    url.pathname !== "/kwadra" ||
    url.username !== "kwadra_app"
  )
    throw new Error(
      "This helper only upgrades the generated local development database.",
    );
  const credentials = JSON.parse(
    await readFile(path.join(root, ".local/postgres/credentials.json"), "utf8"),
  );
  if (url.password !== credentials.app)
    throw new Error(
      "The configured database does not match the generated development cluster.",
    );
  await localPostgres();
  const pool = createPool();
  const counts = () =>
    pool.query(
      `SELECT json_build_object('properties',(SELECT count(*) FROM properties),'units',(SELECT count(*) FROM units),'tenants',(SELECT count(*) FROM tenants),'leases',(SELECT count(*) FROM leases),'invoices',(SELECT count(*) FROM invoices),'payments',(SELECT count(*) FROM payments)) AS counts`,
    );
  try {
    const before = (await counts()).rows[0].counts;
    await migrate(pool);
    const after = (await counts()).rows[0].counts;
    assert.deepEqual(
      after,
      before,
      "Retained portfolio counts must not change during an additive migration.",
    );
    console.log(
      JSON.stringify({
        upgraded: true,
        migrations: (
          await pool.query("SELECT count(*)::int n FROM schema_migrations")
        ).rows[0].n,
        retained: after,
      }),
    );
  } finally {
    await pool.end();
  }
}
await upgrade().catch(() => {
  console.error(
    "Local upgrade could not be completed. Check the generated local database and connection; no reset was attempted and credentials were not printed.",
  );
  process.exitCode = 1;
});
