import { createPool, migrate } from "./db.js";
import { seed } from "./seed.js";
import { validateConfig } from "./config.js";
import { config, root } from "./config.js";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { runJobs } from "./jobs.js";
import { totp, encryptSecret } from "./security.js";
import { demoMfaSecret } from "./phase-seed.js";
import { randomBytes, randomUUID } from "node:crypto";
import { z } from "zod";
import { transaction } from "./db.js";

validateConfig();
const pool = createPool();
try {
  switch (process.argv[2]) {
    case "migrate":
      await migrate(pool);
      break;
    case "seed":
      await seed(pool);
      break;
    case "jobs":
      console.log(await runJobs(pool));
      break;
    case "mail": {
      if (config.production)
        throw new Error("The local mail inbox is disabled in production.");
      const rows = (
        await pool.query(
          "SELECT destination,title,body,status FROM delivery_logs WHERE channel='email' ORDER BY created_at DESC LIMIT 20",
        )
      ).rows;
      for (const row of rows) console.log(JSON.stringify(row, null, 2));
      break;
    }
    case "admin-code": {
      if (config.production)
        throw new Error("Demo authenticator codes are disabled in production.");
      console.log("Development moderator code: " + totp(demoMfaSecret));
      break;
    }
    case "admin-enroll": {
      const email = z
        .email()
        .parse(process.argv.find((a) => a.startsWith("--email="))?.slice(8));
      const bytes = randomBytes(20);
      let bits = "",
        secret = "";
      for (const byte of bytes) bits += byte.toString(2).padStart(8, "0");
      for (const group of bits.match(/.{5}/g) ?? [])
        secret += "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"[parseInt(group, 2)];
      await transaction(pool, async (db) => {
        const user = (
          await db.query(
            "SELECT id,email_verified_at FROM users WHERE lower(email)=lower($1) AND NOT disabled FOR UPDATE",
            [email],
          )
        ).rows[0];
        if (!user?.email_verified_at)
          throw new Error(
            "Create and verify the account before enrolling platform MFA.",
          );
        const organization = randomUUID();
        await db.query(
          "INSERT INTO organizations(id,name) VALUES($1,'Platform moderation')",
          [organization],
        );
        await db.query(
          "INSERT INTO memberships(organization_id,user_id,role,all_properties) VALUES($1,$2,'owner',true)",
          [organization, user.id],
        );
        await db.query(
          "UPDATE users SET platform_admin=true,mfa_secret=$2,last_mfa_counter=NULL WHERE id=$1",
          [user.id, await encryptSecret(secret)],
        );
        await db.query("DELETE FROM sessions WHERE user_id=$1", [user.id]);
      });
      console.log(
        `Enroll this private authenticator URI and keep it out of logs: otpauth://totp/Kwadra:${encodeURIComponent(email)}?secret=${secret}&issuer=Kwadra&digits=6&period=30`,
      );
      break;
    }
    case "reset": {
      if (
        config.production ||
        !process.argv.includes("--confirm=RESET_KWADRA_DEVELOPMENT")
      ) {
        throw new Error(
          "Reset requires development mode and --confirm=RESET_KWADRA_DEVELOPMENT.",
        );
      }
      const url = new URL(config.databaseUrl);
      const credentials = JSON.parse(
        await readFile(
          path.join(root, ".local/postgres/credentials.json"),
          "utf8",
        ),
      );
      if (
        url.hostname !== "127.0.0.1" ||
        url.port !== "55432" ||
        url.pathname !== "/kwadra" ||
        url.username !== "kwadra_app" ||
        url.password !== credentials.app
      ) {
        throw new Error(
          "Reset is restricted to the isolated database created by npm run dev.",
        );
      }
      await pool.query("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
      await migrate(pool);
      await seed(pool);
      console.log("Only the isolated Kwadra development database was reset.");
      break;
    }
    case "inspect": {
      const result =
        await pool.query(`SELECT 'properties' AS entity,count(*)::int AS records FROM properties
        UNION ALL SELECT 'units',count(*)::int FROM units UNION ALL SELECT 'tenants',count(*)::int FROM tenants
        UNION ALL SELECT 'leases',count(*)::int FROM leases UNION ALL SELECT 'invoices',count(*)::int FROM invoices
        UNION ALL SELECT 'repairs',count(*)::int FROM maintenance_tickets UNION ALL SELECT 'payments',count(*)::int FROM payments`);
      console.table(result.rows);
      break;
    }
    default:
      throw new Error("Use migrate, seed, inspect or reset.");
  }
} finally {
  await pool.end();
}
