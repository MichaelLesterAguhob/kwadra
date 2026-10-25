import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import nodemailer from "nodemailer";
import type { Db } from "./db.js";
import { config, root } from "./config.js";
import { readFile } from "node:fs/promises";

export async function queueMail(
  db: Db,
  orgId: string | null,
  userId: string | null,
  email: string,
  title: string,
  body: string,
  sourceKey: string,
) {
  await db.query(
    `INSERT INTO delivery_logs(id,organization_id,recipient_id,channel,destination,title,body,source_key,status)
    VALUES($1,$2,$3,'email',$4,$5,$6,$7,'pending') ON CONFLICT DO NOTHING`,
    [randomUUID(), orgId, userId, email, title, body, sourceKey],
  );
}
export async function notify(
  db: Db,
  orgId: string | null,
  userId: string,
  title: string,
  body: string,
  sourceKey: string,
  service = false,
  inquiryId: string | null = null,
) {
  const user = (
    await db.query("SELECT email FROM users WHERE id=$1 AND NOT disabled", [
      userId,
    ])
  ).rows[0];
  if (!user) return;
  const pref = (
    await db.query("SELECT * FROM notification_preferences WHERE user_id=$1", [
      userId,
    ])
  ).rows[0] ?? { in_app: true, email: false };
  if (pref.in_app || service) {
    const noticeId = randomUUID();
    await db.query(
      `INSERT INTO notifications(id,organization_id,recipient_id,title,body,source_key,inquiry_id)
    VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT DO NOTHING`,
      [noticeId, orgId, userId, title, body, sourceKey, inquiryId],
    );
  }
  if (pref.email)
    await queueMail(db, orgId, userId, user.email, title, body, sourceKey);
}
export async function deliverMail(row: any) {
  if (process.env.EMAIL_DELIVERY_ENABLED === "true" && process.env.SMTP_HOST) {
    const transport = nodemailer.createTransport({
      host: process.env.SMTP_HOST,
      port: Number(process.env.SMTP_PORT ?? 587),
      secure: process.env.SMTP_SECURE === "true",
      requireTLS: process.env.SMTP_SECURE !== "true",
      connectionTimeout: 10000,
      greetingTimeout: 10000,
      socketTimeout: 10000,
      ...(process.env.SMTP_CA_FILE
        ? { tls: { ca: await readFile(process.env.SMTP_CA_FILE) } }
        : {}),
      auth: process.env.SMTP_USER
        ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASSWORD }
        : undefined,
    });
    await transport.sendMail({
      from: process.env.MAIL_FROM,
      to: row.destination,
      subject: row.title,
      text: row.body,
      messageId: `<${row.id}@kwadra.local>`,
    });
  } else {
    if (config.production)
      throw new Error("Email transport is not configured.");
    const directory = path.join(root, ".local/mail");
    await mkdir(directory, { recursive: true });
    // Stable filename makes a retry safe without duplicate local messages.
    await writeFile(
      path.join(directory, row.id + ".json"),
      JSON.stringify(
        { to: row.destination, subject: row.title, body: row.body },
        null,
        2,
      ),
      { mode: 0o600 },
    );
  }
}
