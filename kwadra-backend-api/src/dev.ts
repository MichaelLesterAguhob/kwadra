import { existsSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { config, root } from "./config.js";
import { localPostgres } from "./local-postgres.js";
import { createPool, migrate } from "./db.js";
import { seed } from "./seed.js";
import { startServer } from "./server.js";

if (config.production)
  throw new Error("Use npm start with a managed database for production.");
let ownsLocalCluster = false;
let cluster: Awaited<ReturnType<typeof localPostgres>>["cluster"] | undefined;
const envPath = path.join(root, ".env");
const localCredentials = path.join(
  root,
  ".local",
  "postgres",
  "credentials.json",
);
// Existing externally configured databases are used without starting a cluster.
if (
  !config.databaseUrl ||
  (existsSync(localCredentials) &&
    new URL(config.databaseUrl).port === "55432" &&
    new URL(config.databaseUrl).hostname === "127.0.0.1")
) {
  const local = await localPostgres();
  cluster = local.cluster;
  ownsLocalCluster = true;
  config.databaseUrl = local.url;
  if (!existsSync(envPath))
    await writeFile(
      envPath,
      `DATABASE_URL=${local.url}\nHOST=0.0.0.0\nPORT=3000\nNODE_ENV=development\nCOOKIE_SECURE=false\nDATABASE_SSL=false\nCORS_ORIGINS=http://localhost:3000,http://127.0.0.1:3000,http://localhost:8080\n`,
      { mode: 0o600, flag: "wx" },
    );
  console.log(
    "Isolated PostgreSQL is running on 127.0.0.1:55432. Connection details are in the ignored .env file.",
  );
}
const setupPool = createPool();
try {
  if (ownsLocalCluster) {
    await migrate(setupPool);
    await seed(setupPool);
  } else {
    console.log(
      "Using configured database without automatic migration or demo seeding.",
    );
  }
} finally {
  await setupPool.end();
}
const { server, pool } = await startServer();
let stopping = false;
const shutdown = async () => {
  if (stopping) return;
  stopping = true;
  server.close();
  server.closeIdleConnections();
  await pool.end();
  await cluster?.stop();
  process.exit(0);
};
process.once("SIGINT", () => void shutdown());
process.once("SIGTERM", () => void shutdown());
