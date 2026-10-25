import { readFile } from "node:fs/promises";
import path from "node:path";
import type pg from "pg";
import { fixtureId, demoPassword } from "./seed.js";
import { transaction } from "./db.js";
import { hashPassword, type Context } from "./auth.js";
import { encryptSecret } from "./security.js";
import { storeFile } from "./files.js";
import { root } from "./config.js";
import { vacancy } from "./marketplace.js";

export const demoMfaSecret = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP";
export async function seedPhaseFixtures(pool: pg.Pool) {
  const org = fixtureId("org"),
    owner = fixtureId("owner"),
    password = await hashPassword(demoPassword);
  await transaction(
    pool,
    async (db) => {
      const exists = await db.query("SELECT 1 FROM organizations WHERE id=$1", [
        org,
      ]);
      if (!exists.rowCount) return;
      await db.query(
        "INSERT INTO users(id,name,email,password_hash,email_verified_at,marketplace_account) VALUES($1,'Demo Renter','renter@example.com',$2,now(),true) ON CONFLICT DO NOTHING",
        [fixtureId("seeker"), password],
      );
      await db.query(
        "UPDATE users SET email_verified_at=coalesce(email_verified_at,now()) WHERE id=ANY($1::uuid[])",
        [
          [
            owner,
            fixtureId("staff"),
            fixtureId("viewer"),
            fixtureId("other-owner"),
          ],
        ],
      );
      for (const [key, email, name, tenantIndex] of [
        ["tenant-user", "isabel.reyes@example.com", "Isabel Reyes", 0],
        ["tenant-user-2", "miguel.cruz@example.com", "Miguel Cruz", 1],
      ] as const) {
        const userId = fixtureId(key);
        await db.query(
          "INSERT INTO users(id,name,email,password_hash,email_verified_at) VALUES($1,$2,$3,$4,now()) ON CONFLICT DO NOTHING",
          [userId, name, email, password],
        );
        await db.query(
          "INSERT INTO memberships(organization_id,user_id,role,all_properties) VALUES($1,$2,'tenant',false) ON CONFLICT DO NOTHING",
          [org, userId],
        );
        await db.query(
          "UPDATE tenants SET user_id=$3 WHERE organization_id=$1 AND id=$2 AND user_id IS NULL",
          [org, fixtureId("tenant-" + tenantIndex), userId],
        );
      }
      const platformOrg = fixtureId("platform-org"),
        admin = fixtureId("moderator");
      await db.query(
        "INSERT INTO organizations(id,name) VALUES($1,'Kwadra Platform Moderation') ON CONFLICT DO NOTHING",
        [platformOrg],
      );
      await db.query(
        "INSERT INTO users(id,name,email,password_hash,email_verified_at,platform_admin,mfa_secret) VALUES($1,'Demo Moderator','platform@example.com',$2,now(),true,$3) ON CONFLICT DO NOTHING",
        [admin, password, await encryptSecret(demoMfaSecret)],
      );
      await db.query(
        "INSERT INTO memberships(organization_id,user_id,role,all_properties) VALUES($1,$2,'owner',true) ON CONFLICT DO NOTHING",
        [platformOrg, admin],
      );
      const ctx: Context = {
        orgId: org,
        userId: owner,
        role: "owner",
        allProperties: true,
        tokenHash: "",
        csrf: "",
      };
      for (const name of [
        "Wi-Fi",
        "Parking",
        "Furnished",
        "Air conditioning",
        "Laundry",
        "Pets allowed",
      ])
        await db.query(
          "INSERT INTO amenities(id,name) VALUES($1,$2) ON CONFLICT DO NOTHING",
          [fixtureId("amenity-" + name), name],
        );
      if (
        !(
          await db.query(
            "SELECT 1 FROM publisher_verifications WHERE organization_id=$1",
            [org],
          )
        ).rowCount
      ) {
        const file = await storeFile(
          db,
          ctx,
          {
            filename: "fictional-development-evidence.pdf",
            mediaType: "application/pdf",
            base64: Buffer.from(
              "%PDF-1.4\n% Fictional development review fixture only. Not real identity evidence.\n%%EOF",
            ).toString("base64"),
          },
          "verification",
        );
        await db.query(
          "INSERT INTO publisher_verifications(organization_id,status,attachment_id,submitted_by,reviewed_by,reviewed_at,notes) VALUES($1,'verified',$2,$3,$4,now(),'Synthetic local development publisher; no real-world verification claimed.')",
          [org, file.id, owner, admin],
        );
      }
      for (let index = 0; index < 3; index++) {
        const id = fixtureId("listing-" + index),
          unitId = fixtureId(`unit-${index}-7`);
        if (
          (
            await db.query(
              "SELECT 1 FROM listings WHERE organization_id=$1 AND unit_id=$2",
              [org, unitId],
            )
          ).rowCount
        )
          continue;
        try {
          await vacancy(db, org, unitId);
        } catch {
          continue;
        }
        const unit = (
          await db.query("SELECT rent FROM units WHERE id=$1", [unitId])
        ).rows[0];
        if (!unit) continue;
        await db.query(
          `INSERT INTO listings(id,organization_id,unit_id,title,description,location_label,advertised_rent,move_in_cost,house_rules,status,published_at,created_by)
        VALUES($1,$2,$3,$4,$5,$6,$7,$7,'Quiet hours from 10 PM. Discuss the complete rental terms with the landlord.','approved',now(),$8)`,
          [
            id,
            org,
            unitId,
            [
              "The Palm · Bright city studio (Demo)",
              "Casa Verde · A place to settle in (Demo)",
              "Sundown · Your own little corner (Demo)",
            ][index],
            "Fictional listing for local Kwadra testing. A comfortable home with nearby everyday essentials. This sample is not a real rental offer.",
            [
              "Lahug, Cebu City",
              "Banilad, Mandaue City",
              "Guadalupe, Cebu City",
            ][index],
            unit.rent,
            owner,
          ],
        );
        const key = ["residence", "apartment", "studio"][index],
          bytes = await readFile(
            path.join(root, `../apps/management/assets/images/${key}.jpg`),
          );
        const photo = await storeFile(
          db,
          ctx,
          {
            filename: key + ".jpg",
            mediaType: "image/jpeg",
            base64: bytes.toString("base64"),
          },
          "listing",
        );
        await db.query(
          "INSERT INTO listing_photos(organization_id,listing_id,attachment_id,position) VALUES($1,$2,$3,0)",
          [org, id, photo.id],
        );
        for (const name of ["Wi-Fi", "Furnished"])
          await db.query(
            "INSERT INTO listing_amenities(organization_id,listing_id,amenity_id) VALUES($1,$2,$3)",
            [org, id, fixtureId("amenity-" + name)],
          );
      }
    },
    org,
  );
}
