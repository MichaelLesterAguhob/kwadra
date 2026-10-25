import { pathToFileURL } from "node:url";
import { config, validateConfig } from "./config.js";
import { createPool } from "./db.js";
import { createApp } from "./app.js";
import { runJobs } from "./jobs.js";

export async function startServer() {
  validateConfig();
  const pool = createPool();
  await pool.query("SELECT 1");
  const app = createApp(pool);
  const server = app.listen(config.port, config.host, () =>
    console.log(
      `Kwadra API: http://localhost:${config.port} | API explorer: http://localhost:${config.port}/docs`,
    ),
  );
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      await runJobs(pool);
    } catch {
      console.error(
        "Background work failed; durable records remain available for retry.",
      );
    } finally {
      running = false;
    }
  };
  const timer = setInterval(() => void tick(), 60000);
  timer.unref();
  server.on("close", () => clearInterval(timer));
  return { server, pool };
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const { server, pool } = await startServer();
  let stopping = false;
  const shutdown = () => {
    if (stopping) return;
    stopping = true;
    // Foreground notification streams are long-lived. Bound shutdown so they
    // cannot hold a container open; transactions still drain through the pool.
    const deadline = setTimeout(() => server.closeAllConnections(), 5000);
    deadline.unref();
    server.close(() => {
      clearTimeout(deadline);
      void pool.end().then(() => process.exit(0));
    });
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}
