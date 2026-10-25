// Disposable local browser QA backend. Never uses the development database and
// never starts email delivery jobs. Stop the process when QA is finished.
import net from "node:net";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { config, root } from "../src/config.js";
import { localPostgres } from "../src/local-postgres.js";
import { createPool, migrate } from "../src/db.js";
import { seed } from "../src/seed.js";
import { createApp } from "../src/app.js";
if (config.production) throw new Error("Browser QA is development-only.");
const probe = net.createServer();
await new Promise<void>((r) => probe.listen(0, "127.0.0.1", r));
const port = (probe.address() as net.AddressInfo).port;
await new Promise<void>((r) => probe.close(() => r()));
const local = await localPostgres({
  port,
  directory: path.join(root, ".local/browser-databases", randomUUID()),
});
const pool = createPool(local.url);
await migrate(pool);
await seed(pool);
const app = createApp(pool, { testing: true });
const server = app.listen(3001, "127.0.0.1", () =>
  console.log("Disposable browser QA: http://127.0.0.1:3001 (no email jobs)"),
);
async function stop() {
  server.close();
  server.closeIdleConnections();
  await pool.end();
  await local.cluster.stop();
  process.exit(0);
}
process.once("SIGINT", () => void stop());
process.once("SIGTERM", () => void stop());
