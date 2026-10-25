import pg from "pg";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { config, root } from "./config.js";

// DATE is a calendar day, not a JavaScript timestamp in the host timezone.
pg.types.setTypeParser(1082, (value) => value);
export type Db = pg.PoolClient;
export function createPool(connectionString = config.databaseUrl) {
  const pool = new pg.Pool({
    connectionString,
    max: 10,
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 10000,
    ssl: config.ssl ? { rejectUnauthorized: true } : undefined,
  });
  pool.on("error", () => console.error("An idle database connection failed."));
  return pool;
}

export async function transaction<T>(
  pool: pg.Pool,
  fn: (db: Db) => Promise<T>,
  organizationId?: string,
): Promise<T> {
  const db = await pool.connect();
  try {
    await db.query("BEGIN");
    await db.query("SET LOCAL statement_timeout = '15s'");
    if (organizationId) {
      // Serialize this organization's writes: archive, lease, billing and edits
      // cannot race each other. Database constraints provide a second boundary.
      await db.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        organizationId,
      ]);
    }
    const result = await fn(db);
    await db.query("COMMIT");
    return result;
  } catch (error) {
    await db.query("ROLLBACK");
    throw error;
  } finally {
    db.release();
  }
}

export async function migrate(pool: pg.Pool) {
  await transaction(pool, async (db) => {
    await db.query(
      "SELECT pg_advisory_xact_lock(hashtextextended('kwadra-migrations', 0))",
    );
    await db.query(
      "CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())",
    );
    const directory = path.join(root, "migrations");
    for (const name of (await readdir(directory))
      .filter((f) => f.endsWith(".sql"))
      .sort()) {
      if (
        (
          await db.query("SELECT 1 FROM schema_migrations WHERE name=$1", [
            name,
          ])
        ).rowCount
      )
        continue;
      await db.query(await readFile(path.join(directory, name), "utf8"));
      await db.query("INSERT INTO schema_migrations(name) VALUES ($1)", [name]);
      console.log(`Applied ${name}`);
    }
  });
}
