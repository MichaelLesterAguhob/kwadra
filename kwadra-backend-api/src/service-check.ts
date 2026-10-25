import { validateConfig, root } from "./config.js";
import { createPool } from "./db.js";
import { existsSync } from "node:fs";
import path from "node:path";
let pool: ReturnType<typeof createPool> | undefined;
try {
  validateConfig();
  pool = createPool();
  const migrations = await pool.query("SELECT name FROM schema_migrations");
  if (
    !migrations.rows.some(
      (r) => r.name === "005_accounts_and_notifications.sql",
    )
  )
    throw new Error("Apply backend migrations first.");
  console.log("Database: connected; accounts migration applied.");
  console.log(
    `Flutter web build: ${existsSync(path.join(root, "../apps/management/build/web/index.html")) ? "present" : "missing; build before deploying"}.`,
  );
  console.log("Notifications: in-app only. Phone push is not implemented.");
  console.log(
    `Email delivery: ${process.env.EMAIL_DELIVERY_ENABLED === "true" ? "explicitly enabled in local configuration" : "disabled; use the development inbox for local verification codes"}.`,
  );
  console.log(
    `Google sign-in: ${process.env.GOOGLE_WEB_CLIENT_ID ? "configured; real-account acceptance remains required" : "disabled; OAuth client IDs needed"}.`,
  );
} catch {
  console.error(
    "Service check failed. Check configuration, connectivity and migrations locally. Secrets were not printed.",
  );
  process.exitCode = 1;
} finally {
  await pool?.end();
}
