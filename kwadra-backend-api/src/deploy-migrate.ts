import { createPool, migrate } from "./db.js";
import { validateConfig } from "./config.js";
validateConfig();
const pool = createPool();
try {
  await migrate(pool);
  await pool.query("REVOKE ALL ON schema_migrations FROM kwadra_app");
  await pool.query("GRANT SELECT ON schema_migrations TO kwadra_app");
  console.log(
    "Migrations applied; runtime role cannot change migration history.",
  );
} finally {
  await pool.end();
}
