import { createHash, randomUUID } from "node:crypto";
import type pg from "pg";
import { hashPassword, type Context } from "./auth.js";
import { transaction } from "./db.js";
import { audit, generateInvoices } from "./operations.js";
import { manilaToday } from "./contracts.js";
import { seedPhaseFixtures } from "./phase-seed.js";

export function fixtureId(label: string) {
  const h = createHash("sha256")
    .update("kwadra:" + label)
    .digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
export const demoPassword = "KwadraDemo!2026";
export async function seed(pool: pg.Pool) {
  if (process.env.NODE_ENV === "production")
    throw new Error("Demo seeding is disabled in production.");
  const passwordHash = await hashPassword(demoPassword),
    orgId = fixtureId("org"),
    ownerId = fixtureId("owner");
  await transaction(
    pool,
    async (db) => {
      const inserted = await db.query(
        "INSERT INTO organizations(id,name) VALUES($1,'Kwadra Living') ON CONFLICT DO NOTHING RETURNING id",
        [orgId],
      );
      if (!inserted.rowCount) {
        console.log(
          "Demo organization already exists; existing data was preserved.",
        );
        return;
      }
      for (const [key, email, name, role, all] of [
        ["owner", "alex@example.com", "Alex Santos", "owner", true],
        ["staff", "staff@example.com", "Sam Reyes", "staff", false],
        ["viewer", "viewer@example.com", "Pat Cruz", "viewer", true],
      ] as const) {
        const id = fixtureId(key);
        await db.query(
          "INSERT INTO users(id,email,name,password_hash) VALUES($1,$2,$3,$4)",
          [id, email, name, passwordHash],
        );
        await db.query(
          "INSERT INTO memberships(organization_id,user_id,role,all_properties) VALUES($1,$2,$3,$4)",
          [orgId, id, role, all],
        );
      }
      const properties = [
        ["The Palm Residences", "Lahug, Cebu City", "Apartment", "residence"],
        [
          "Casa Verde Apartments",
          "Banilad, Mandaue City",
          "Apartment",
          "apartment",
        ],
        ["Sundown Studios", "Guadalupe, Cebu City", "Boarding house", "studio"],
      ];
      const names = [
        "Isabel Reyes",
        "Miguel Cruz",
        "Sofia Garcia",
        "Daniel Lim",
        "Andrea Flores",
        "Paolo Mendoza",
        "Camille Tan",
        "Joshua Ramos",
        "Bea Dela Cruz",
        "Marco Villanueva",
        "Nina Torres",
        "Rafael Aquino",
        "Ella Bautista",
        "Gabriel Ong",
        "Mia Navarro",
        "Carlo Diaz",
        "Julia Santiago",
        "Enzo Castillo",
      ];
      const today = manilaToday(),
        month = today.slice(0, 7),
        nextYear = Number(today.slice(0, 4)) + 1;
      let tenantIndex = 0;
      for (const [index, p] of properties.entries()) {
        const propertyId = fixtureId("property-" + index);
        await db.query(
          "INSERT INTO properties(id,organization_id,name,address,type,image,notes) VALUES($1,$2,$3,$4,$5,$6,$7)",
          [
            propertyId,
            orgId,
            ...p,
            "Fictional sample property for development testing.",
          ],
        );
        if (index === 0)
          await db.query(
            "INSERT INTO property_assignments(organization_id,user_id,property_id) VALUES($1,$2,$3)",
            [orgId, fixtureId("staff"), propertyId],
          );
        for (let n = 1; n <= 8; n++) {
          const unitId = fixtureId(`unit-${index}-${n}`),
            rent =
              index === 0 ? "9500.00" : index === 1 ? "8500.00" : "6000.00";
          await db.query(
            "INSERT INTO units(id,organization_id,property_id,code,type,rent,capacity,floor,maintenance) VALUES($1,$2,$3,$4,$5,$6,2,$7,$8)",
            [
              unitId,
              orgId,
              propertyId,
              `${["A", "B", "S"][index]}-${String(n).padStart(2, "0")}`,
              index === 2 ? "Studio" : "1 Bedroom",
              rent,
              n <= 4 ? "Ground floor" : "2nd floor",
              index === 1 && n === 8,
            ],
          );
          if (n <= 6) {
            const tenantId = fixtureId("tenant-" + tenantIndex),
              leaseId = fixtureId("lease-" + tenantIndex),
              name = names[tenantIndex++];
            await db.query(
              "INSERT INTO tenants(id,organization_id,name,email,phone) VALUES($1,$2,$3,$4,$5)",
              [
                tenantId,
                orgId,
                name,
                `${name.toLowerCase().replaceAll(" ", ".")}@example.com`,
                "0917000" + String(tenantIndex).padStart(4, "0"),
              ],
            );
            await db.query(
              "INSERT INTO leases(id,organization_id,unit_id,starts_on,ends_on,rent,due_day,deposit_terms) VALUES($1,$2,$3,$4,$5,$6,5,$6)",
              [
                leaseId,
                orgId,
                unitId,
                month + "-01",
                `${nextYear}-12-31`,
                rent,
              ],
            );
            await db.query(
              "INSERT INTO lease_participants(organization_id,lease_id,tenant_id,is_primary) VALUES($1,$2,$3,true)",
              [orgId, leaseId, tenantId],
            );
          }
        }
      }
      const ctx: Context = {
        orgId,
        userId: ownerId,
        role: "owner",
        allProperties: true,
        tokenHash: "",
        csrf: "",
      };
      await generateInvoices(db, ctx, { period: month });
      for (const [i, title, category, priority, status] of [
        [0, "Kitchen faucet is leaking", "Plumbing", "Urgent", "Open"],
        [1, "Hallway light needs replacing", "Electrical", "Normal", "Open"],
        [
          2,
          "Air conditioner needs cleaning",
          "Appliance",
          "Normal",
          "In progress",
        ],
        [3, "Door lock is loose", "General", "Low", "Open"],
        [4, "Bathroom drain cleared", "Plumbing", "Normal", "Resolved"],
      ] as const) {
        const id = fixtureId("ticket-" + i),
          unitId = fixtureId(`unit-${i % 3}-${i + 1}`);
        await db.query(
          "INSERT INTO maintenance_tickets(id,organization_id,unit_id,title,description,category,priority,status,reported_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)",
          [
            id,
            orgId,
            unitId,
            title,
            "Fictional repair request. Please inspect and arrange maintenance.",
            category,
            priority,
            status,
            ownerId,
          ],
        );
        await db.query(
          "INSERT INTO maintenance_events(id,organization_id,ticket_id,actor_id,detail) VALUES($1,$2,$3,$4,$5)",
          [
            randomUUID(),
            orgId,
            id,
            ownerId,
            `${today} · ${status} by Alex Santos`,
          ],
        );
      }
      await audit(
        db,
        ctx,
        "Sample workspace created",
        "Synthetic properties, tenants, leases, rent charges and repairs. No payments.",
        "settings",
        orgId,
      );
      const secondOrg = fixtureId("other-org"),
        secondOwner = fixtureId("other-owner");
      await db.query(
        "INSERT INTO organizations(id,name) VALUES($1,'Separate Demo Rentals')",
        [secondOrg],
      );
      await db.query(
        "INSERT INTO users(id,name,email,password_hash) VALUES($1,'Beth Garcia','beth@example.com',$2)",
        [secondOwner, passwordHash],
      );
      await db.query(
        "INSERT INTO memberships(organization_id,user_id,role,all_properties) VALUES($1,$2,'owner',true)",
        [secondOrg, secondOwner],
      );
      console.log(
        "Created fictional demo accounts and rental records. Payment tables are empty.",
      );
    },
    orgId,
  );
  await seedPhaseFixtures(pool);
}
