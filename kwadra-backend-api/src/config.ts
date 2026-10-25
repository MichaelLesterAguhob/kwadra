import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

export const root = fileURLToPath(new URL("../", import.meta.url));
const envPath = path.join(root, ".env");
if (existsSync(envPath)) process.loadEnvFile(envPath);

export const config = {
  databaseUrl: process.env.DATABASE_URL ?? "",
  ssl: process.env.DATABASE_SSL === "true",
  host: process.env.HOST ?? "0.0.0.0",
  port: Number(process.env.PORT ?? 3000),
  production: process.env.NODE_ENV === "production",
  cookieSecure: process.env.COOKIE_SECURE === "true",
  origins: (
    process.env.CORS_ORIGINS ?? "http://localhost:3000,http://127.0.0.1:3000"
  )
    .split(",")
    .map((v) => v.trim())
    .filter(Boolean),
};

export function validateConfig() {
  if (!config.databaseUrl)
    throw new Error(
      "Set DATABASE_URL, or run npm run dev for an isolated development database.",
    );
  if (config.production && !config.cookieSecure)
    throw new Error(
      "Production requires COOKIE_SECURE=true and an HTTPS reverse proxy.",
    );
  if (
    config.production &&
    !/^[a-fA-F0-9]{64}$/.test(process.env.ENCRYPTION_KEY ?? "")
  )
    throw new Error(
      "Production requires a 32-byte ENCRYPTION_KEY in hexadecimal for MFA.",
    );
  if (config.production && !process.env.PUBLIC_ORIGIN?.startsWith("https://"))
    throw new Error("Production requires the canonical HTTPS PUBLIC_ORIGIN.");
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535)
    throw new Error("Invalid PORT.");
  const smtpPort = Number(process.env.SMTP_PORT ?? 587);
  if (
    process.env.EMAIL_DELIVERY_ENABLED === "true" &&
    process.env.SMTP_HOST &&
    (!Number.isInteger(smtpPort) || smtpPort < 1 || smtpPort > 65535)
  )
    throw new Error("SMTP_PORT must be a valid port.");
  if (
    config.production &&
    process.env.EMAIL_DELIVERY_ENABLED === "true" &&
    process.env.SMTP_HOST &&
    !process.env.MAIL_FROM
  )
    throw new Error("Set MAIL_FROM for production email delivery.");
  if (
    process.env.EMAIL_DELIVERY_ENABLED === "true" &&
    process.env.SMTP_USER &&
    !process.env.SMTP_PASSWORD
  )
    throw new Error("Set SMTP_PASSWORD when SMTP_USER is configured.");
  if (
    process.env.GOOGLE_WEB_CLIENT_ID &&
    !/^[a-zA-Z0-9-]+\.apps\.googleusercontent\.com$/.test(
      process.env.GOOGLE_WEB_CLIENT_ID,
    )
  )
    throw new Error("Set a valid Google web OAuth client ID.");
}
