import type { Express, Request, Response } from "express";
import type pg from "pg";
import { rateLimit } from "express-rate-limit";
import { z } from "zod";
import { transaction, type Db } from "./db.js";
import {
  identityRoutes,
  teamSnapshot,
  inviteMember,
  updateMember,
} from "./identity.js";
import {
  write,
  createLease,
  audit,
  checkRevision,
  saveTenant,
} from "./operations.js";
import { leaseAccess } from "./access.js";
import { canManage, canWrite, unitAccess, type Context } from "./auth.js";
import { requireCondition, ApiError } from "./errors.js";
import {
  portal,
  tenantTicket,
  commentTicket,
  assignTicket,
  requestMoveOut,
  updateMoveOut,
} from "./tenant.js";
import {
  createMeter,
  addReading,
  correctReading,
  readingPreview,
  issueReading,
  sharedPreview,
  issueShared,
} from "./utilities.js";
import {
  publicSearch,
  publicListing,
  publicJoins,
  eligible,
  saveListing,
  addListingPhoto,
  submitListing,
  requestVerification,
  createInquiry,
  inquiryView,
  seekerMessage,
  seekerViewing,
  reportListing,
  replyInquiry,
  updateViewing,
  privateInquiry,
} from "./marketplace.js";
import { randomUUID } from "node:crypto";
import {
  moderationSnapshot,
  platformAccess,
  reviewPublisher,
  reviewListing,
  appealCase,
  suspendPublisher,
} from "./moderation.js";
import { attachFile, readFile } from "./files.js";
import { operationsSnapshot } from "./extras.js";
import {
  announce,
  notificationSnapshot,
  updatePreferences,
} from "./communications.js";

const id = (req: Request) => z.uuid().parse(req.params.id);
async function read(
  pool: pg.Pool,
  req: Request,
  res: Response,
  fn: (db: Db, ctx: Context) => Promise<unknown>,
) {
  res.json(await transaction(pool, (db) => fn(db, req.auth!)));
}
export function publicPhaseRoutes(
  app: Express,
  pool: pg.Pool,
  testing = false,
) {
  const identity = identityRoutes(pool);
  if (!testing)
    app.use(
      [
        "/api/v1/identity",
        "/api/v1/public/listings/:id/inquiries",
        "/api/v1/public/listings/:id/report",
        "/api/v1/public/inquiries",
      ],
      rateLimit({
        windowMs: 15 * 60_000,
        limit: 40,
        standardHeaders: "draft-8",
        legacyHeaders: false,
      }),
    );
  app.post("/api/v1/identity/verify", identity.verify);
  app.post("/api/v1/identity/resend-verification", identity.resend);
  app.post("/api/v1/identity/recover", identity.recover);
  app.post("/api/v1/identity/reset", identity.reset);
  app.post("/api/v1/identity/accept-invitation", identity.accept);
  app.get("/api/v1/public/listings", async (req, res) =>
    res.json(await transaction(pool, (db) => publicSearch(db, req.query))),
  );
  app.get("/api/v1/public/amenities", async (_req, res) =>
    res.json({
      data: (await pool.query("SELECT id,name FROM amenities ORDER BY name"))
        .rows,
    }),
  );
  app.get("/api/v1/public/listings/:id", async (req, res) =>
    res.json({
      data: await transaction(pool, (db) => publicListing(db, id(req))),
    }),
  );
  app.get("/api/v1/public/photos/:id", async (req, res) => {
    const row = (
      await pool.query(
        `SELECT a.content,a.media_type ${publicJoins} JOIN listing_photos ph ON ph.organization_id=l.organization_id AND ph.listing_id=l.id
      JOIN attachments a ON a.organization_id=ph.organization_id AND a.id=ph.attachment_id WHERE ${eligible} AND a.id=$1 AND a.purpose='listing' LIMIT 1`,
        [id(req)],
      )
    ).rows[0];
    if (!row) throw new ApiError(404, "Photo unavailable.", "NOT_FOUND");
    res.setHeader("Cache-Control", "no-store");
    res.type(row.media_type).send(row.content);
  });
  app.post("/api/v1/public/listings/:id/inquiries", async (req, res) =>
    res
      .status(201)
      .json(
        await transaction(pool, (db) => createInquiry(db, id(req), req.body)),
      ),
  );
  app.post("/api/v1/public/listings/:id/report", async (req, res) =>
    res.json(
      await transaction(pool, (db) => reportListing(db, id(req), req.body)),
    ),
  );
  app.get("/api/v1/public/inquiries/:id", async (req, res) =>
    res.json(
      await transaction(pool, (db) =>
        inquiryView(db, id(req), req.header("X-Inquiry-Token") ?? ""),
      ),
    ),
  );
  app.post("/api/v1/public/inquiries/:id/messages", async (req, res) =>
    res.json(
      await transaction(pool, (db) =>
        seekerMessage(
          db,
          id(req),
          req.header("X-Inquiry-Token") ?? "",
          req.body,
        ),
      ),
    ),
  );
  app.post("/api/v1/public/inquiries/:id/viewings", async (req, res) =>
    res.json(
      await transaction(pool, (db) =>
        seekerViewing(
          db,
          id(req),
          req.header("X-Inquiry-Token") ?? "",
          req.body,
        ),
      ),
    ),
  );
}
export function protectedPhaseRoutes(app: Express, pool: pg.Pool) {
  app.get("/api/v1/tenant/portal", async (req, res) =>
    read(pool, req, res, portal),
  );
  app.post("/api/v1/tenant/tickets", async (req, res) =>
    write(
      pool,
      req,
      res,
      "tenant-ticket",
      (db, ctx) => tenantTicket(db, ctx, req.body),
      { selfService: true },
    ),
  );
  app.post("/api/v1/move-outs", async (req, res) =>
    write(
      pool,
      req,
      res,
      "request-move-out",
      (db, ctx) => requestMoveOut(db, ctx, req.body),
      { selfService: true },
    ),
  );
  app.put("/api/v1/move-outs/:id", async (req, res) =>
    write(pool, req, res, "update-move-out", (db, ctx) =>
      updateMoveOut(db, ctx, id(req), req.body),
    ),
  );
  app.post("/api/v1/tickets/:id/comments", async (req, res) =>
    write(
      pool,
      req,
      res,
      "ticket-comment",
      (db, ctx) => commentTicket(db, ctx, id(req), req.body),
      { selfService: true },
    ),
  );
  app.put("/api/v1/tickets/:id/assignment", async (req, res) =>
    write(pool, req, res, "ticket-assignment", (db, ctx) =>
      assignTicket(db, ctx, id(req), req.body),
    ),
  );
  app.post("/api/v1/tickets/:id/files", async (req, res) =>
    write(
      pool,
      req,
      res,
      "ticket-file",
      (db, ctx) => attachFile(db, ctx, "maintenance", id(req), req.body),
      { selfService: true },
    ),
  );
  app.post("/api/v1/leases/:id/files", async (req, res) =>
    write(pool, req, res, "lease-file", (db, ctx) =>
      attachFile(db, ctx, "lease", id(req), req.body),
    ),
  );
  app.get("/api/v1/files/:id", async (req, res) =>
    read(pool, req, res, async (db, ctx) => {
      const f = await readFile(db, ctx, id(req));
      return {
        id: f.id,
        filename: f.filename,
        mediaType: f.media_type,
        base64: f.content.toString("base64"),
      };
    }),
  );
  app.get("/api/v1/notifications", async (req, res) =>
    read(pool, req, res, notificationSnapshot),
  );
  app.put("/api/v1/notifications/preferences", async (req, res) =>
    write(
      pool,
      req,
      res,
      "preferences",
      (db, ctx) => updatePreferences(db, ctx, req.body),
      { selfService: true },
    ),
  );
  app.post("/api/v1/notifications/:id/read", async (req, res) =>
    write(
      pool,
      req,
      res,
      "read-notification",
      async (db, ctx) => {
        const r = await db.query(
          "UPDATE notifications SET read_at=coalesce(read_at,now()) WHERE organization_id=$1 AND recipient_id=$2 AND id=$3 RETURNING id",
          [ctx.orgId, ctx.userId, id(req)],
        );
        requireCondition(r.rowCount, "Notification not found.", 404);
        return { id: id(req) };
      },
      { selfService: true },
    ),
  );
  app.get("/api/v1/platform/review", async (req, res) =>
    read(pool, req, res, moderationSnapshot),
  );
  app.get("/api/v1/platform/listings/:id/preview", async (req, res) =>
    read(pool, req, res, async (db, ctx) => {
      platformAccess(ctx);
      const listing = (
        await db.query(
          `SELECT l.id,l.title,l.description,l.location_label AS location,l.status,l.revision,
           u.id AS "publisherId",u.name AS "publisherName",u.email AS "publisherEmail",u.disabled AS "publisherDisabled"
           FROM listings l JOIN users u ON u.id=l.created_by WHERE l.id=$1`,
          [id(req)],
        )
      ).rows[0];
      requireCondition(listing, "Listing not found.", 404);
      const photos = (
        await db.query(
          "SELECT a.id,a.filename FROM attachments a JOIN listing_photos p ON p.organization_id=a.organization_id AND p.attachment_id=a.id WHERE p.listing_id=$1 ORDER BY p.position",
          [id(req)],
        )
      ).rows;
      return { listing, photos };
    }),
  );
  app.get("/api/v1/platform/files/:id", async (req, res) =>
    read(pool, req, res, async (db, ctx) => {
      platformAccess(ctx);
      const f = (
        await db.query(
          `SELECT a.* FROM attachments a WHERE a.id=$1 AND
      (a.purpose='verification' AND EXISTS(SELECT 1 FROM publisher_verifications v WHERE v.organization_id=a.organization_id AND v.attachment_id=a.id)
       OR a.purpose='listing' AND EXISTS(SELECT 1 FROM listing_photos p WHERE p.organization_id=a.organization_id AND p.attachment_id=a.id))`,
          [id(req)],
        )
      ).rows[0];
      requireCondition(f, "Review attachment not found.", 404);
      return {
        id: f.id,
        filename: f.filename,
        mediaType: f.media_type,
        base64: f.content.toString("base64"),
      };
    }),
  );
  app.put("/api/v1/platform/publishers/:id", async (req, res) =>
    write(pool, req, res, "review-publisher", (db, ctx) =>
      reviewPublisher(db, ctx, id(req), req.body),
    ),
  );
  app.put("/api/v1/platform/listings/:id", async (req, res) =>
    write(pool, req, res, "review-listing", (db, ctx) =>
      reviewListing(db, ctx, id(req), req.body),
    ),
  );
  app.post("/api/v1/platform/accounts", async (req, res) =>
    write(pool, req, res, "suspend-account", (db, ctx) =>
      suspendPublisher(db, ctx, req.body),
    ),
  );

  // A tenant cannot enter any management route, including old direct-ID routes.
  app.use("/api/v1", (req, _res, next) => {
    requireCondition(
      req.auth?.role !== "tenant",
      "Use the tenant portal for your own tenancy records.",
      403,
    );
    next();
  });
  app.get("/api/v1/operations", async (req, res) =>
    read(pool, req, res, operationsSnapshot),
  );
  app.get("/api/v1/team", async (req, res) =>
    read(pool, req, res, teamSnapshot),
  );
  app.post("/api/v1/team/invitations", async (req, res) =>
    write(pool, req, res, "invite-member", (db, ctx) =>
      inviteMember(db, ctx, req.body),
    ),
  );
  app.put("/api/v1/team/members/:id", async (req, res) =>
    write(pool, req, res, "update-member", (db, ctx) =>
      updateMember(db, ctx, id(req), req.body),
    ),
  );
  app.post("/api/v1/announcements", async (req, res) =>
    write(pool, req, res, "announce", (db, ctx) => announce(db, ctx, req.body)),
  );
  app.get("/api/v1/deliveries", async (req, res) =>
    read(pool, req, res, async (db, ctx) => {
      canManage(ctx);
      return {
        data: (
          await db.query(
            'SELECT id,channel,destination,title,status,attempts,last_error AS "lastError",created_at AS created FROM delivery_logs WHERE organization_id=$1 ORDER BY created_at DESC LIMIT 200',
            [ctx.orgId],
          )
        ).rows,
      };
    }),
  );
  app.post("/api/v1/deliveries/:id/retry", async (req, res) =>
    write(pool, req, res, "retry-delivery", async (db, ctx) => {
      canManage(ctx);
      const r = await db.query(
        "UPDATE delivery_logs SET next_attempt_at=now(),attempts=0,status='pending' WHERE organization_id=$1 AND id=$2 AND status='failed' RETURNING id",
        [ctx.orgId, id(req)],
      );
      requireCondition(r.rowCount, "Failed delivery not found.", 404);
      return { id: id(req) };
    }),
  );
  app.post("/api/v1/leases/:id/activate", async (req, res) =>
    write(pool, req, res, "activate-lease", async (db, ctx) => {
      const b = z
          .object({ revision: z.number().int().positive() })
          .strict()
          .parse(req.body),
        l = await leaseAccess(db, ctx, id(req));
      checkRevision(l, b.revision);
      requireCondition(
        l.status === "draft",
        "Only a draft can be activated.",
        409,
      );
      const u = await unitAccess(db, ctx, l.unit_id);
      requireCondition(!u.maintenance, "This unit is under maintenance.", 409);
      const invalid = await db.query(
        `SELECT 1 FROM properties p WHERE p.organization_id=$1 AND p.id=$2 AND p.archived UNION ALL
      SELECT 1 FROM lease_participants lp JOIN tenants t ON t.organization_id=lp.organization_id AND t.id=lp.tenant_id WHERE lp.organization_id=$1 AND lp.lease_id=$3 AND t.archived`,
        [ctx.orgId, u.property_id, l.id],
      );
      const count = Number(
        (
          await db.query(
            "SELECT count(*) AS n FROM lease_participants WHERE organization_id=$1 AND lease_id=$2",
            [ctx.orgId, l.id],
          )
        ).rows[0].n,
      );
      requireCondition(
        !invalid.rowCount && count > 0 && count <= u.capacity,
        "Restore archived records and check capacity before activation.",
        409,
      );
      await db.query(
        "UPDATE leases SET status='active',revision=revision+1 WHERE organization_id=$1 AND id=$2",
        [ctx.orgId, l.id],
      );
      await audit(
        db,
        ctx,
        "Lease activated",
        "Billing schedule ready",
        "lease",
        l.id,
        u.property_id,
      );
      return { id: l.id };
    }),
  );
  app.post("/api/v1/leases/:id/renew", async (req, res) =>
    write(pool, req, res, "renew-lease", async (db, ctx) => {
      const old = await leaseAccess(db, ctx, id(req));
      requireCondition(
        old.status !== "draft",
        "Activate a draft before renewing.",
      );
      requireCondition(
        req.body.unitId === old.unit_id && req.body.start > old.ends_on,
        "Renewal must use the same unit and start after the existing term.",
      );
      const result = await createLease(db, ctx, req.body);
      await db.query(
        "UPDATE leases SET renewal_of=$3 WHERE organization_id=$1 AND id=$2",
        [ctx.orgId, result.id, old.id],
      );
      return result;
    }),
  );
  app.post("/api/v1/utilities/meters", async (req, res) =>
    write(pool, req, res, "create-meter", (db, ctx) =>
      createMeter(db, ctx, req.body),
    ),
  );
  app.post("/api/v1/utilities/readings", async (req, res) =>
    write(pool, req, res, "add-reading", (db, ctx) =>
      addReading(db, ctx, req.body),
    ),
  );
  app.put("/api/v1/utilities/readings/:id", async (req, res) =>
    write(pool, req, res, "correct-reading", (db, ctx) =>
      correctReading(db, ctx, id(req), req.body),
    ),
  );
  app.get("/api/v1/utilities/readings/:id/preview", async (req, res) =>
    read(pool, req, res, (db, ctx) => readingPreview(db, ctx, id(req))),
  );
  app.post("/api/v1/utilities/readings/:id/issue", async (req, res) =>
    write(pool, req, res, "issue-reading", (db, ctx) =>
      issueReading(db, ctx, id(req), req.body),
    ),
  );
  app.post("/api/v1/utilities/shared/preview", async (req, res) =>
    read(pool, req, res, (db, ctx) => sharedPreview(db, ctx, req.body)),
  );
  app.post("/api/v1/utilities/shared/issue", async (req, res) =>
    write(pool, req, res, "issue-shared", (db, ctx) =>
      issueShared(db, ctx, req.body),
    ),
  );
  app.post("/api/v1/listings", async (req, res) =>
    write(pool, req, res, "create-listing", (db, ctx) =>
      saveListing(db, ctx, req.body),
    ),
  );
  app.put("/api/v1/listings/:id", async (req, res) =>
    write(pool, req, res, "update-listing", (db, ctx) =>
      saveListing(db, ctx, req.body, id(req)),
    ),
  );
  app.post("/api/v1/listings/:id/photos", async (req, res) =>
    write(pool, req, res, "listing-photo", (db, ctx) =>
      addListingPhoto(db, ctx, id(req), req.body),
    ),
  );
  app.post("/api/v1/listings/:id/action", async (req, res) =>
    write(pool, req, res, "listing-action", (db, ctx) =>
      submitListing(db, ctx, id(req), req.body),
    ),
  );
  app.post("/api/v1/publisher-verification", async (req, res) =>
    write(pool, req, res, "request-verification", (db, ctx) =>
      requestVerification(db, ctx, req.body),
    ),
  );
  app.post("/api/v1/moderation/cases/:id/appeal", async (req, res) =>
    write(pool, req, res, "appeal-listing", (db, ctx) =>
      appealCase(db, ctx, id(req), req.body),
    ),
  );
  app.post("/api/v1/inquiries/:id/reply", async (req, res) =>
    write(pool, req, res, "reply-inquiry", (db, ctx) =>
      replyInquiry(db, ctx, id(req), req.body),
    ),
  );
  app.post("/api/v1/inquiries/:id/convert", async (req, res) =>
    write(pool, req, res, "convert-inquiry", async (db, ctx) => {
      const b = z
          .object({ revision: z.number().int().positive() })
          .strict()
          .parse(req.body),
        row = await privateInquiry(db, ctx, id(req));
      checkRevision(row, b.revision);
      requireCondition(
        ctx.allProperties,
        "Organization-wide tenant access is required.",
        403,
      );
      requireCondition(
        !row.converted_tenant_id,
        "This inquiry already has a tenant profile.",
        409,
      );
      let tenant = (
        await db.query(
          "SELECT id FROM tenants WHERE organization_id=$1 AND lower(email)=lower($2) AND NOT archived",
          [ctx.orgId, row.email],
        )
      ).rows[0];
      if (!tenant)
        tenant = await saveTenant(db, ctx, {
          id: randomUUID(),
          name: row.name,
          email: row.email,
          phone: row.phone,
          emergency: "",
          archived: false,
          revision: 0,
        });
      await db.query(
        "UPDATE inquiries SET converted_tenant_id=$3,revision=revision+1 WHERE organization_id=$1 AND id=$2",
        [ctx.orgId, row.id, tenant.id],
      );
      await audit(
        db,
        ctx,
        "Inquiry linked to tenant profile",
        "Lease creation remains a separate landlord workflow.",
        "inquiry",
        row.id,
      );
      return { tenantId: tenant.id };
    }),
  );
  app.put("/api/v1/viewings/:id", async (req, res) =>
    write(pool, req, res, "update-viewing", (db, ctx) =>
      updateViewing(db, ctx, id(req), req.body),
    ),
  );
}
