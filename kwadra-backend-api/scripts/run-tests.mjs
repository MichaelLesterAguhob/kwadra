import { spawn } from "node:child_process";
import { readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../", import.meta.url));
const files = (await readdir(new URL("../test/", import.meta.url)))
  .filter((n) => n.endsWith(".test.ts"))
  .map((n) => fileURLToPath(new URL("../test/" + n, import.meta.url)));
// Never contact configured real email/push providers from automated tests.
const child = spawn(
  process.execPath,
  ["--import", "tsx", "--test", "--test-concurrency=1", ...files],
  {
    cwd: root,
    stdio: "inherit",
    env: {
      ...process.env,
      NODE_ENV: "test",
      SMTP_HOST: "",
      EMAIL_DELIVERY_ENABLED: "false",
      GOOGLE_WEB_CLIENT_ID: "",
    },
  },
);
child.on("exit", (code) => (process.exitCode = code ?? 1));
child.on("error", () => {
  console.error("Could not start the isolated test runner.");
  process.exitCode = 1;
});
