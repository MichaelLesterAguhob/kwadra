import { randomBytes } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
const domain = process.argv.find((v) => v.startsWith("--domain="))?.slice(9);
const email = process.argv.find((v) => v.startsWith("--email="))?.slice(8);
if (
  !domain ||
  !/^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$/i.test(domain) ||
  !email ||
  !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
)
  throw new Error(
    "Pass --domain=rentals.example.com --email=owner@example.com",
  );
const runtime = randomBytes(32).toString("hex"),
  migration = randomBytes(32).toString("hex");
const output = fileURLToPath(
  new URL("../deploy/.env.production", import.meta.url),
);
await writeFile(
  output,
  `# Private deployment configuration. Never commit or paste this file.
KWADRA_DOMAIN=${domain}
ACME_EMAIL=${email}
APP_VERSION=0.6.0
RUNTIME_DB_PASSWORD=${runtime}
MIGRATION_DB_PASSWORD=${migration}
DATABASE_URL=postgresql://kwadra_app:${runtime}@database:5432/kwadra
MIGRATION_DATABASE_URL=postgresql://kwadra_migrate:${migration}@database:5432/kwadra
ENCRYPTION_KEY=${randomBytes(32).toString("hex")}
EMAIL_DELIVERY_ENABLED=false
SMTP_HOST=
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=
SMTP_PASSWORD=
MAIL_FROM=
GOOGLE_WEB_CLIENT_ID=
GOOGLE_IOS_CLIENT_ID=
`,
  { flag: "wx", mode: 0o600 },
);
console.log(
  "Created deploy/.env.production. Configure optional Google sign-in locally. Email delivery remains disabled. Existing configuration is never overwritten.",
);
