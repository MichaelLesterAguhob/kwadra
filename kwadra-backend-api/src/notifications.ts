import type { Express } from "express";
import type pg from "pg";
import { z } from "zod";
import { authenticate } from "./auth.js";
import { ApiError } from "./errors.js";
const visible = `recipient_id=$1 AND (organization_id IS NULL OR EXISTS
 (SELECT 1 FROM memberships m WHERE m.organization_id=notifications.organization_id AND m.user_id=$1 AND m.active))`;
export function personalNotificationRoutes(app: Express, pool: pg.Pool) {
  const connections = new Map<string, number>();
  app.use("/api/v1/account", authenticate(pool, true));
  app.get("/api/v1/account/notifications", async (req, res) => {
    const userId = req.account!.userId;
    const [rows, count, prefs] = await Promise.all([
      pool.query(
        `SELECT id,title,body,created_at AS created,read_at AS "readAt",inquiry_id AS "inquiryId" FROM notifications WHERE ${visible} ORDER BY created_at DESC,id DESC LIMIT 100`,
        [userId],
      ),
      pool.query(
        `SELECT count(*)::int AS n FROM notifications WHERE ${visible} AND read_at IS NULL`,
        [userId],
      ),
      pool.query(
        'SELECT in_app AS "inApp" FROM notification_preferences WHERE user_id=$1',
        [userId],
      ),
    ]);
    res.json({
      notifications: rows.rows,
      unread: count.rows[0].n,
      preferences: prefs.rows[0] ?? { inApp: true },
    });
  });
  app.post("/api/v1/account/notifications/read", async (req, res) => {
    const b = z
      .object({ ids: z.array(z.uuid()).min(1).max(100) })
      .strict()
      .parse(req.body);
    await pool.query(
      `UPDATE notifications SET read_at=coalesce(read_at,now()) WHERE ${visible} AND id=ANY($2::uuid[])`,
      [req.account!.userId, b.ids],
    );
    res.json({ message: "Notifications marked as read." });
  });
  app.put("/api/v1/account/notification-preferences", async (req, res) => {
    const b = z.object({ inApp: z.boolean() }).strict().parse(req.body);
    await pool.query(
      "INSERT INTO notification_preferences(user_id,in_app) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET in_app=excluded.in_app",
      [req.account!.userId, b.inApp],
    );
    res.json({ data: b });
  });
  // Foreground updates: bounded shared-pool queries, no reserved DB connection per client.
  // Only invalidation signals are streamed. Private content stays in the scoped inbox.
  app.get("/api/v1/account/notifications/events", async (req, res) => {
    const userId = req.account!.userId;
    if ((connections.get(userId) ?? 0) >= 5)
      throw new ApiError(
        429,
        "Too many live notification connections.",
        "RATE_LIMITED",
      );
    connections.set(userId, (connections.get(userId) ?? 0) + 1);
    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Accel-Buffering", "no");
    res.flushHeaders();
    let stopped = false,
      busy = false,
      signature = "";
    const tick = async () => {
      if (stopped || busy) return;
      busy = true;
      try {
        const valid = await pool.query(
          "SELECT 1 FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=$1 AND s.expires_at>now() AND NOT u.disabled",
          [req.account!.tokenHash],
        );
        if (stopped) return;
        if (!valid.rowCount) {
          res.write('data: {"expired":true}\n\n');
          res.end();
          return;
        }
        const snapshot = (
          await pool.query(
            `SELECT count(*)::int n,count(*) FILTER(WHERE read_at IS NULL)::int unread,max(created_at)::text created,max(read_at)::text read FROM notifications WHERE ${visible}`,
            [req.account!.userId],
          )
        ).rows[0];
        if (stopped) return;
        const next = JSON.stringify(snapshot);
        if (next !== signature) {
          signature = next;
          res.write('data: {"changed":true}\n\n');
        } else res.write(": heartbeat\n\n");
      } catch {
        res.end();
      } finally {
        busy = false;
      }
    };
    const timer = setInterval(() => void tick(), 5000),
      lifetime = setTimeout(() => res.end(), 60 * 60 * 1000);
    res.on("close", () => {
      stopped = true;
      clearInterval(timer);
      clearTimeout(lifetime);
      const remaining = (connections.get(userId) ?? 1) - 1;
      if (remaining > 0) connections.set(userId, remaining);
      else connections.delete(userId);
    });
    void tick();
  });
}
