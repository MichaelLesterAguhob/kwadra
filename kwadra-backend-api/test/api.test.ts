import { before, after, test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import net from "node:net";
import path from "node:path";
import type { Server } from "node:http";
import type pg from "pg";
import { localPostgres } from "../src/local-postgres.js";
import { root } from "../src/config.js";
import { createPool, migrate } from "../src/db.js";
import { createApp } from "../src/app.js";
import { seed, fixtureId, demoPassword } from "../src/seed.js";
import { manilaToday } from "../src/contracts.js";
import { totp } from "../src/security.js";
import { demoMfaSecret } from "../src/phase-seed.js";
import { runJobs } from "../src/jobs.js";
import { readFile } from "node:fs/promises";

test("in-place Phase 3 migration preserves old charges, edited records and historical occupancy", async () => {
  const admin = cluster.getPgClient("postgres", "127.0.0.1");
  await admin.connect();
  await admin.query("CREATE DATABASE kwadra_upgrade_test OWNER kwadra_app");
  const upgradeUrl = new URL(pool.options.connectionString!);
  upgradeUrl.pathname = "/kwadra_upgrade_test";
  const upgrade = createPool(upgradeUrl.toString());
  try {
    await upgrade.query(
      "CREATE TABLE schema_migrations(name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())",
    );
    for (const name of ["001_core.sql", "002_planned_modules.sql"]) {
      await upgrade.query(
        await readFile(path.join(root, "migrations", name), "utf8"),
      );
      await upgrade.query("INSERT INTO schema_migrations(name) VALUES($1)", [
        name,
      ]);
    }
    const [o, p, u, t, l, invoice, user] = Array.from({ length: 7 }, () =>
      randomUUID(),
    );
    await upgrade.query(
      "INSERT INTO users(id,email,name,password_hash) VALUES($1,'retained@example.com','Retained user','legacy-password')",
      [user],
    );
    await upgrade.query(
      "INSERT INTO organizations(id,name) VALUES($1,'Retained organization')",
      [o],
    );
    await upgrade.query(
      "INSERT INTO properties(id,organization_id,name,address,type,notes,revision) VALUES($1,$2,'Edited existing property','Cebu','Apartment','Keep this edited note',9)",
      [p, o],
    );
    await upgrade.query(
      "INSERT INTO units(id,organization_id,property_id,code,type,rent,capacity) VALUES($1,$2,$3,'OLD-01','Studio',1250.50,2)",
      [u, o, p],
    );
    await upgrade.query(
      "INSERT INTO tenants(id,organization_id,name) VALUES($1,$2,'Retained tenant')",
      [t, o],
    );
    await upgrade.query(
      "INSERT INTO leases(id,organization_id,unit_id,starts_on,ends_on,rent,due_day,status,terminated_on) VALUES($1,$2,$3,'2025-01-01','2025-12-31',1250.50,31,'ended','2025-10-15')",
      [l, o, u],
    );
    await upgrade.query(
      "INSERT INTO lease_participants(organization_id,lease_id,tenant_id) VALUES($1,$2,$3)",
      [o, l, t],
    );
    await upgrade.query(
      "INSERT INTO invoices(id,organization_id,lease_id,number,period,due_on,amount) VALUES($1,$2,$3,'OLD-INVOICE','2025-09-01','2025-09-30',1250.50)",
      [invoice, o, l],
    );
    const before = (
      await upgrade.query(
        "SELECT id,status,occupancy::text,rent,terminated_on FROM leases",
      )
    ).rows;
    await migrate(upgrade);
    await migrate(upgrade);
    assert.deepEqual(
      (
        await upgrade.query(
          "SELECT id,status,occupancy::text,rent,terminated_on FROM leases",
        )
      ).rows,
      before,
    );
    assert.deepEqual(
      (await upgrade.query("SELECT name,notes,revision FROM properties"))
        .rows[0],
      {
        name: "Edited existing property",
        notes: "Keep this edited note",
        revision: 9,
      },
    );
    assert.deepEqual(
      (await upgrade.query("SELECT number,amount,kind FROM invoices")).rows[0],
      { number: "OLD-INVOICE", amount: "1250.50", kind: "rent" },
    );
    assert.equal(
      (await upgrade.query("SELECT count(*)::int AS n FROM lease_participants"))
        .rows[0].n,
      1,
    );
    assert.ok(
      (await upgrade.query("SELECT email_verified_at FROM users")).rows[0]
        .email_verified_at,
    );
    await assert.rejects(
      upgrade.query(
        "INSERT INTO leases(id,organization_id,unit_id,starts_on,ends_on,rent,due_day) VALUES($1,$2,$3,'2025-01-02','2025-02-01',1000,5)",
        [randomUUID(), o, u],
      ),
      /conflicting key/,
    );
  } finally {
    await upgrade.end();
    await admin.query("DROP DATABASE kwadra_upgrade_test");
    await admin.end();
  }
});

let pool: pg.Pool,
  server: Server,
  cluster: Awaited<ReturnType<typeof localPostgres>>["cluster"],
  base: string;
type Session = { token: string; org?: string };
let owner: Session, other: Session, staff: Session, viewer: Session;
let tenantOne: Session, tenantTwo: Session, moderator: Session;
const month = manilaToday().slice(0, 7),
  org = fixtureId("org");
async function unusedPort() {
  const listener = net.createServer();
  await new Promise<void>((resolve) =>
    listener.listen(0, "127.0.0.1", resolve),
  );
  const port = (listener.address() as net.AddressInfo).port;
  await new Promise<void>((resolve) => listener.close(() => resolve()));
  return port;
}
async function request(
  method: string,
  route: string,
  body?: unknown,
  session?: Session,
  key = randomUUID(),
  extra: Record<string, string> = {},
) {
  const response = await fetch(base + route, {
    method,
    headers: {
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...(session
        ? {
            Authorization: `Bearer ${session.token}`,
            ...(session.org ? { "X-Organization-Id": session.org } : {}),
          }
        : {}),
      "Idempotency-Key": key,
      ...extra,
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  return {
    status: response.status,
    body: (await response.json()) as any,
    headers: response.headers,
  };
}
async function login(email: string, mfaCode?: string): Promise<Session> {
  const r = await request("POST", "/api/v1/auth/login", {
    email,
    password: demoPassword,
    client: "native",
    ...(mfaCode ? { mfaCode } : {}),
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return { token: r.body.token, org: r.body.organizations[0]?.id };
}
const propertyBody = (id = randomUUID()) => ({
  id,
  name: "Integration property",
  address: "Cebu City",
  type: "Apartment",
  image: "residence",
  notes: "Synthetic test",
  archived: false,
  revision: 0,
});
const tenantBody = (id = randomUUID()) => ({
  id,
  name: "Test Tenant",
  email: `${id}@example.com`,
  phone: "09170000000",
  emergency: "",
  archived: false,
  revision: 0,
});
const unitBody = (
  propertyId: string,
  id = randomUUID(),
  code = id.slice(0, 8),
) => ({
  id,
  propertyId,
  code,
  type: "Studio",
  rent: 125050,
  capacity: 2,
  floor: "Ground floor",
  maintenance: false,
  revision: 0,
});
const leaseBody = (unitId: string, tenantIds: string[], id = randomUUID()) => ({
  id,
  unitId,
  tenantIds,
  start: month + "-01",
  end: manilaToday().slice(0, 4) + "-12-31",
  rent: 125050,
  deposit: 0,
  dueDay: 31,
});
async function createPortfolio() {
  const p = propertyBody(),
    t = tenantBody(),
    u = unitBody(p.id);
  for (const [route, body] of [
    ["properties", p],
    ["units", u],
    ["tenants", t],
  ] as const) {
    const r = await request("POST", "/api/v1/" + route, body, owner);
    assert.equal(r.status, 200, JSON.stringify(r.body));
  }
  return { p, u, t };
}

before(
  async () => {
    // Every test invocation owns a new cluster; never truncate the user's DB.
    const local = await localPostgres({
      directory: path.join(root, ".local", "tests", randomUUID()),
      port: await unusedPort(),
    });
    cluster = local.cluster;
    pool = createPool(local.url);
    await migrate(pool);
    await migrate(pool);
    await seed(pool);
    server = createApp(pool, { testing: true }).listen(0, "127.0.0.1");
    await new Promise<void>((resolve) => server.once("listening", resolve));
    base = `http://127.0.0.1:${(server.address() as net.AddressInfo).port}`;
    owner = await login("alex@example.com");
    other = await login("beth@example.com");
    staff = await login("staff@example.com");
    viewer = await login("viewer@example.com");
    tenantOne = await login("isabel.reyes@example.com");
    tenantTwo = await login("miguel.cruz@example.com");
  },
  { timeout: 120000 },
);
after(async () => {
  if (server) {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
  await pool?.end();
  await cluster?.stop();
});

test("health, readiness and repeatable migrations against real PostgreSQL", async () => {
  assert.equal((await request("GET", "/health")).body.status, "ok");
  assert.equal((await request("GET", "/ready")).body.database, "postgresql");
  const tables = await pool.query(
    "SELECT count(*)::int AS n FROM information_schema.tables WHERE table_schema='public'",
  );
  assert.ok(tables.rows[0].n >= 40);
  assert.equal(
    (await pool.query("SELECT count(*)::int AS n FROM schema_migrations"))
      .rows[0].n,
    5,
  );
});
test("authentication rejects bad credentials and protected unauthenticated reads", async () => {
  const unknown = await request("POST", "/api/v1/auth/login", {
    email: "unknown-account@example.com",
    password: "wrong",
    client: "native",
  });
  assert.equal(unknown.status, 401);
  assert.equal(unknown.body.error.message, "Email or password is incorrect.");
  assert.equal(unknown.body.error.code, "INVALID_CREDENTIALS");
  assert.equal(
    (
      await request("POST", "/api/v1/auth/login", {
        email: "alex@example.com",
        password: "wrong",
        client: "native",
      })
    ).status,
    401,
  );
  assert.equal((await request("GET", "/api/v1/workspace")).status, 401);
  assert.equal(
    (
      await request("GET", "/api/v1/workspace", undefined, {
        ...owner,
        token: "0".repeat(64),
      })
    ).status,
    401,
  );
});
test("web sessions use HttpOnly cookies, restore without stored tokens, enforce CSRF and revoke on logout", async () => {
  const signed = await request("POST", "/api/v1/auth/login", {
    email: "alex@example.com",
    password: demoPassword,
    client: "web",
  });
  assert.equal(signed.status, 200);
  assert.equal(signed.body.token, undefined);
  const setCookie = signed.headers.get("set-cookie")!;
  assert.match(setCookie, /HttpOnly/i);
  assert.match(setCookie, /SameSite=Lax/i);
  const cookie = setCookie.split(";")[0],
    headers = { Cookie: cookie, "X-Organization-Id": org };
  const restored = await request(
    "GET",
    "/api/v1/auth/me",
    undefined,
    undefined,
    undefined,
    { Cookie: cookie },
  );
  assert.equal(restored.status, 200);
  assert.equal(restored.body.user.email, "alex@example.com");
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/properties",
        propertyBody(),
        undefined,
        undefined,
        headers,
      )
    ).status,
    403,
  );
  const logout = await request(
    "POST",
    "/api/v1/auth/logout",
    {},
    undefined,
    undefined,
    { ...headers, "X-CSRF-Token": signed.body.csrfToken },
  );
  assert.equal(logout.status, 200);
  assert.equal(
    (
      await request("GET", "/api/v1/auth/me", undefined, undefined, undefined, {
        Cookie: cookie,
      })
    ).status,
    401,
  );
});
test("workspace returns exact centavos, authorized seed data and server dates", async () => {
  const r = await request("GET", "/api/v1/workspace", undefined, owner);
  assert.equal(r.status, 200);
  assert.equal(r.body.properties.length, 3);
  assert.equal(r.body.units.length, 24);
  assert.equal(r.body.tenants.length, 18);
  assert.equal(r.body.invoices.length, 18);
  assert.equal(r.body.units[0].rent, 950000);
  assert.equal(r.body.today, manilaToday());
  assert.equal(r.body.permissions.canManage, true);
  assert.ok(r.body.properties[0].revision > 0);
});
test("another organization cannot read resources, select the first organization or create foreign relationships", async () => {
  const id = fixtureId("property-0");
  assert.equal(
    (await request("GET", `/api/v1/properties/${id}`, undefined, other)).status,
    404,
  );
  assert.equal(
    (await request("GET", "/api/v1/workspace", undefined, { ...other, org }))
      .status,
    403,
  );
  assert.equal(
    (await request("POST", "/api/v1/units", unitBody(id), other)).status,
    404,
  );
  const snapshot = await request("GET", "/api/v1/workspace", undefined, other);
  assert.equal(snapshot.body.tenants.length, 0);
});
test("property-scoped staff only see assigned units, linked tenants, charges and history", async () => {
  const r = await request("GET", "/api/v1/workspace", undefined, staff);
  assert.equal(r.body.properties.length, 1);
  assert.equal(r.body.units.length, 8);
  assert.equal(r.body.tenants.length, 6);
  assert.equal(r.body.invoices.length, 6);
  assert.equal(r.body.permissions.canManage, false);
  assert.equal(
    (
      await request(
        "GET",
        `/api/v1/units/${fixtureId("unit-1-1")}`,
        undefined,
        staff,
      )
    ).status,
    404,
  );
  assert.equal(
    (await request("POST", "/api/v1/tenants", tenantBody(), staff)).status,
    403,
  );
  assert.equal(
    (await request("POST", "/api/v1/properties", propertyBody(), staff)).status,
    403,
  );
});
test("viewer cannot mutate records", async () => {
  assert.equal(
    (await request("POST", "/api/v1/properties", propertyBody(), viewer))
      .status,
    403,
  );
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/invoices/generate",
        { period: month },
        viewer,
      )
    ).status,
    403,
  );
});
test("property edits persist and stale updates cannot overwrite newer data", async () => {
  const p = propertyBody();
  assert.equal(
    (await request("POST", "/api/v1/properties", p, owner)).status,
    200,
  );
  const edit = { ...p, name: "Saved through API", revision: 1 };
  assert.equal(
    (await request("PUT", `/api/v1/properties/${p.id}`, edit, owner)).status,
    200,
  );
  const stale = await request(
    "PUT",
    `/api/v1/properties/${p.id}`,
    { ...edit, name: "Stale overwrite" },
    owner,
  );
  assert.equal(stale.status, 409);
  assert.equal(stale.body.error.code, "STALE_RECORD");
  const row = await request(
    "GET",
    `/api/v1/properties/${p.id}`,
    undefined,
    owner,
  );
  assert.equal(row.body.data.name, "Saved through API");
  assert.equal(row.body.data.revision, 2);
  assert.equal(
    (await pool.query("SELECT name FROM properties WHERE id=$1", [p.id]))
      .rows[0].name,
    "Saved through API",
  );
});
test("idempotent retries replay once and conflicting payload reuse is rejected", async () => {
  const p = propertyBody(),
    key = randomUUID();
  const a = await request("POST", "/api/v1/properties", p, owner, key),
    b = await request("POST", "/api/v1/properties", p, owner, key);
  assert.equal(a.status, 200);
  assert.deepEqual(a.body, b.body);
  const conflict = await request(
    "POST",
    "/api/v1/properties",
    { ...p, name: "Changed payload" },
    owner,
    key,
  );
  assert.equal(conflict.status, 409);
  assert.equal(
    (
      await pool.query(
        "SELECT count(*)::int AS n FROM audit_events WHERE resource_id=$1",
        [p.id],
      )
    ).rows[0].n,
    1,
  );
});
test("strict validation, tenant email uniqueness and case-insensitive unit code uniqueness", async () => {
  const { p, u, t } = await createPortfolio();
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/properties",
        { ...propertyBody(), admin: true },
        owner,
      )
    ).status,
    422,
  );
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/units",
        unitBody(p.id, randomUUID(), u.code.toUpperCase()),
        owner,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/tenants",
        { ...tenantBody(), email: t.email.toUpperCase() },
        owner,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/units",
        { ...unitBody(p.id), rent: 1.5 },
        owner,
      )
    ).status,
    422,
  );
});
test("simultaneous overlapping leases cannot double-book a unit", async () => {
  const { u, t } = await createPortfolio(),
    a = leaseBody(u.id, [t.id]),
    b = leaseBody(u.id, [t.id]);
  const responses = await Promise.all([
    request("POST", "/api/v1/leases", a, owner),
    request("POST", "/api/v1/leases", b, owner),
  ]);
  assert.deepEqual(responses.map((r) => r.status).sort(), [200, 409]);
  assert.equal(
    (
      await pool.query(
        "SELECT count(*)::int AS n FROM leases WHERE unit_id=$1",
        [u.id],
      )
    ).rows[0].n,
    1,
  );
});
test("capacity, archived records, reserved maintenance and unsafe archival are enforced", async () => {
  const { p, u, t } = await createPortfolio(),
    t2 = tenantBody();
  await request("POST", "/api/v1/tenants", t2, owner);
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/leases",
        leaseBody(u.id, [t.id, t.id]),
        owner,
      )
    ).status,
    422,
  );
  const l = leaseBody(u.id, [t.id, t2.id]);
  assert.equal((await request("POST", "/api/v1/leases", l, owner)).status, 200);
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/properties/${p.id}`,
        { ...p, revision: 1, archived: true },
        owner,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/tenants/${t.id}`,
        { ...t, revision: 1, archived: true },
        owner,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/units/${u.id}`,
        { ...u, revision: 1, maintenance: true },
        owner,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/units/${u.id}`,
        { ...u, revision: 1, capacity: 1 },
        owner,
      )
    ).status,
    409,
  );
});
test("repeated and concurrent billing creates one exact charge per lease/month; future months fail", async () => {
  const { u, t } = await createPortfolio(),
    l = leaseBody(u.id, [t.id]);
  await request("POST", "/api/v1/leases", l, owner);
  const results = await Promise.all([
    request("POST", "/api/v1/invoices/generate", { period: month }, owner),
    request("POST", "/api/v1/invoices/generate", { period: month }, owner),
  ]);
  assert.ok(results.every((r) => r.status === 200));
  assert.equal(results[1].body.data.created, 0);
  const invoices = (
    await pool.query("SELECT * FROM invoices WHERE lease_id=$1", [l.id])
  ).rows;
  assert.equal(invoices.length, 1);
  assert.equal(invoices[0].amount, "1250.50");
  const [year, m] = month.split("-").map(Number),
    last = new Date(Date.UTC(year, m, 0)).getUTCDate();
  assert.equal(invoices[0].due_on, `${month}-${last}`);
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/invoices/generate",
        { period: "2199-01" },
        owner,
      )
    ).status,
    422,
  );
});
test("lease termination preserves invoices and historical occupancy; future cancellation never occupies", async () => {
  const { u, t } = await createPortfolio(),
    l = leaseBody(u.id, [t.id]);
  await request("POST", "/api/v1/leases", l, owner);
  await request("POST", "/api/v1/invoices/generate", { period: month }, owner);
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/leases/${l.id}/end`,
        { revision: 1 },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await pool.query(
        "SELECT count(*)::int AS n FROM invoices WHERE lease_id=$1",
        [l.id],
      )
    ).rows[0].n,
    1,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/leases/${l.id}/end`,
        { revision: 2 },
        owner,
      )
    ).status,
    409,
  );
  const future = {
    ...leaseBody(u.id, [t.id]),
    start: "2199-01-01",
    end: "2199-12-31",
  };
  assert.equal(
    (await request("POST", "/api/v1/leases", future, owner)).status,
    200,
  );
  await request(
    "POST",
    `/api/v1/leases/${future.id}/end`,
    { revision: 1 },
    owner,
  );
  const row = (
    await pool.query("SELECT status,occupancy FROM leases WHERE id=$1", [
      future.id,
    ])
  ).rows[0];
  assert.equal(row.status, "cancelled");
  assert.equal(row.occupancy, null);
});
test("maintenance history is server-authored and status transitions are controlled", async () => {
  const { u } = await createPortfolio(),
    b = {
      id: randomUUID(),
      unitId: u.id,
      title: "Test repair",
      description: "Synthetic request",
      category: "General",
      priority: "Normal",
      status: "Open",
      revision: 0,
    };
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/tickets",
        { ...b, history: ["forged"] },
        owner,
      )
    ).status,
    422,
  );
  assert.equal(
    (await request("POST", "/api/v1/tickets", b, owner)).status,
    200,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/tickets/${b.id}`,
        { ...b, status: "Resolved", revision: 1 },
        owner,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/tickets/${b.id}`,
        { ...b, status: "In progress", revision: 1 },
        owner,
      )
    ).status,
    200,
  );
  const result = await request(
    "GET",
    `/api/v1/tickets/${b.id}`,
    undefined,
    owner,
  );
  assert.equal(result.body.data.history.length, 2);
  assert.match(result.body.data.history[1], /Alex Santos/);
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/tickets/${b.id}`,
        { ...b, status: "Resolved", revision: 2 },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/tickets/${b.id}`,
        { ...b, status: "Open", revision: 3 },
        owner,
      )
    ).status,
    200,
  );
});
test("foreign keys reject cross-organization links and issued history cannot be rewritten", async () => {
  await assert.rejects(
    pool.query(
      "INSERT INTO units(id,organization_id,property_id,code,type,rent,capacity) VALUES($1,$2,$3,$4,$5,1,1)",
      [randomUUID(), other.org, fixtureId("property-0"), "invalid", "Studio"],
    ),
    { code: "23503" },
  );
  await assert.rejects(
    pool.query("UPDATE invoices SET amount=1 WHERE organization_id=$1", [org]),
    { code: "23514" },
  );
  await assert.rejects(
    pool.query("DELETE FROM audit_events WHERE organization_id=$1", [org]),
    { code: "23514" },
  );
});
test("payment, checkout, proof, receipt and subscription endpoints do not exist or mutate data", async () => {
  for (const route of [
    "payments",
    "payment-proofs",
    "checkout",
    "receipts",
    "subscriptions",
  ]) {
    assert.equal(
      (await request("POST", "/api/v1/" + route, {}, owner)).status,
      404,
    );
  }
  for (const table of [
    "payments",
    "payment_allocations",
    "payment_proofs",
    "receipts",
    "deposit_transactions",
    "provider_events",
    "subscriptions",
  ]) {
    assert.equal(
      (await pool.query(`SELECT count(*)::int AS n FROM ${table}`)).rows[0].n,
      0,
    );
  }
});
test("CORS rejects unknown browser origins and list pagination validates input", async () => {
  assert.equal(
    (
      await request("GET", "/api/v1/workspace", undefined, owner, undefined, {
        Origin: "https://untrusted.invalid",
      })
    ).status,
    403,
  );
  const r = await request(
    "GET",
    "/api/v1/units?page=1&pageSize=2",
    undefined,
    owner,
  );
  assert.equal(r.status, 200);
  assert.equal(r.body.data.length, 2);
  assert.ok(r.body.total >= 24);
  assert.equal(
    (await request("GET", "/api/v1/units?pageSize=1000", undefined, owner))
      .status,
    422,
  );
});
test("development registration creates an isolated owner with a hashed password", async () => {
  const email = `${randomUUID()}@example.com`,
    r = await request("POST", "/api/v1/auth/register", {
      name: "New Owner",
      email,
      password: demoPassword,
      organization: "New Test Org",
    });
  assert.equal(r.status, 201);
  const mail = (
    await pool.query(
      "SELECT body FROM delivery_logs WHERE destination=$1 ORDER BY created_at DESC LIMIT 1",
      [email],
    )
  ).rows[0];
  const code = mail.body.match(/[a-f0-9]{64}/)[0];
  assert.equal(
    (await request("POST", "/api/v1/identity/verify", { token: code })).status,
    200,
  );
  const session = await login(email);
  const snapshot = await request(
    "GET",
    "/api/v1/workspace",
    undefined,
    session,
  );
  assert.equal(snapshot.body.properties.length, 0);
  assert.equal(snapshot.body.permissions.role, "owner");
  const user = (
    await pool.query("SELECT password_hash FROM users WHERE email=$1", [email])
  ).rows[0];
  assert.match(user.password_hash, /^\$argon2id\$/);
  assert.notEqual(user.password_hash, demoPassword);
});
test("membership revocation takes effect on the next request", async () => {
  await pool.query("UPDATE memberships SET active=false WHERE user_id=$1", [
    fixtureId("staff"),
  ]);
  assert.equal(
    (await request("GET", "/api/v1/workspace", undefined, staff)).status,
    403,
  );
});

test("tenant portal exposes only linked leases and blocks all management routes", async () => {
  const a = await request("GET", "/api/v1/tenant/portal", undefined, tenantOne),
    b = await request("GET", "/api/v1/tenant/portal", undefined, tenantTwo);
  assert.equal(a.status, 200);
  assert.equal(a.body.leases.length, 1);
  assert.equal(a.body.leases[0].id, fixtureId("lease-0"));
  assert.equal(b.body.leases[0].id, fixtureId("lease-1"));
  assert.ok(
    a.body.invoices.every((i: any) => i.leaseId === fixtureId("lease-0")),
  );
  for (const route of [
    "workspace",
    "operations",
    "team",
    "properties",
    "tenants",
    "leases/" + fixtureId("lease-1"),
  ])
    assert.equal(
      (await request("GET", "/api/v1/" + route, undefined, tenantOne)).status,
      403,
    );
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/invoices/generate",
        { period: month },
        tenantOne,
      )
    ).status,
    403,
  );
});
test("platform administrator requires MFA and rejects a reused code", async () => {
  assert.equal(totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", 1), "287082");
  const noCode = await request("POST", "/api/v1/auth/login", {
    email: "platform@example.com",
    password: demoPassword,
    client: "native",
  });
  assert.equal(noCode.body.error.code, "MFA_REQUIRED");
  assert.equal(
    (
      await request("POST", "/api/v1/auth/login", {
        email: "platform@example.com",
        password: demoPassword,
        client: "native",
        mfaCode: "abcdef",
      })
    ).status,
    403,
  );
  const code = totp(demoMfaSecret);
  moderator = await login("platform@example.com", code);
  assert.equal(
    (
      await request("POST", "/api/v1/auth/login", {
        email: "platform@example.com",
        password: demoPassword,
        client: "native",
        mfaCode: code,
      })
    ).body.error.code,
    "MFA_INVALID",
  );
  assert.equal(
    (await request("GET", "/api/v1/platform/review", undefined, moderator))
      .status,
    200,
  );
  assert.equal(
    (await request("GET", "/api/v1/platform/review", undefined, owner)).status,
    403,
  );
  assert.equal(
    (
      await request("GET", "/api/v1/workspace", undefined, {
        ...moderator,
        org,
      })
    ).status,
    403,
  );
  const secret = (
    await pool.query("SELECT mfa_secret FROM users WHERE id=$1", [
      fixtureId("moderator"),
    ])
  ).rows[0].mfa_secret;
  assert.notEqual(secret, demoMfaSecret);
});
const pdf = {
  filename: "test-lease.pdf",
  mediaType: "application/pdf",
  base64: Buffer.from("%PDF-1.4\nSynthetic contract test\n%%EOF").toString(
    "base64",
  ),
};
test("private lease documents enforce organization, tenant and moderation access", async () => {
  const r = await request(
    "POST",
    `/api/v1/leases/${fixtureId("lease-0")}/files`,
    pdf,
    owner,
  );
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const fileId = r.body.data.id;
  assert.equal(
    (await request("GET", `/api/v1/files/${fileId}`, undefined, tenantOne))
      .status,
    200,
  );
  assert.equal(
    (await request("GET", `/api/v1/files/${fileId}`, undefined, tenantTwo))
      .status,
    404,
  );
  assert.equal(
    (await request("GET", `/api/v1/files/${fileId}`, undefined, other)).status,
    404,
  );
  assert.equal(
    (
      await request(
        "GET",
        `/api/v1/platform/files/${fileId}`,
        undefined,
        moderator,
      )
    ).status,
    404,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/leases/${fixtureId("lease-0")}/files`,
        {
          ...pdf,
          base64: Buffer.from("<script>bad</script>").toString("base64"),
        },
        owner,
      )
    ).status,
    422,
  );
  const portal = await request(
    "GET",
    "/api/v1/tenant/portal",
    undefined,
    tenantOne,
  );
  assert.ok(portal.body.documents.some((d: any) => d.id === fileId));
});
test("tenant repairs, comments, assignment, resolution and closure are scoped and auditable", async () => {
  const body = {
    leaseId: fixtureId("lease-0"),
    title: "Tenant repair test",
    description: "Please inspect the leaking tap.",
    category: "Plumbing",
    priority: "Normal",
  };
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/tenant/tickets",
        { ...body, leaseId: fixtureId("lease-1") },
        tenantOne,
      )
    ).status,
    404,
  );
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/tenant/tickets",
        { ...body, reportedBy: fixtureId("other-owner") },
        tenantOne,
      )
    ).status,
    422,
  );
  const r = await request("POST", "/api/v1/tenant/tickets", body, tenantOne);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const id = r.body.data.id;
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/tickets/${id}/comments`,
        { body: "More details from the tenant." },
        tenantOne,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/tickets/${id}/comments`,
        { body: "Not my request." },
        tenantTwo,
      )
    ).status,
    404,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/tickets/${id}/assignment`,
        { revision: 1, assignedTo: fixtureId("owner"), close: false },
        owner,
      )
    ).status,
    200,
  );
  const edit = {
    id,
    unitId: fixtureId("unit-0-1"),
    title: body.title,
    description: body.description,
    category: body.category,
    priority: body.priority,
  };
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/tickets/${id}`,
        { ...edit, status: "In progress", revision: 2 },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/tickets/${id}`,
        { ...edit, status: "Resolved", revision: 3 },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/tickets/${id}/assignment`,
        { revision: 4, assignedTo: fixtureId("owner"), close: true },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/tickets/${id}/comments`,
        { body: "A closed comment." },
        tenantOne,
      )
    ).status,
    409,
  );
  const portal = await request(
    "GET",
    "/api/v1/tenant/portal",
    undefined,
    tenantOne,
  );
  assert.ok(portal.body.tickets.find((t: any) => t.id === id).closedAt);
  assert.ok(
    portal.body.comments.some(
      (c: any) => c.body === "More details from the tenant.",
    ),
  );
  assert.ok(
    (
      await request("GET", "/api/v1/notifications", undefined, tenantOne)
    ).body.notifications.some((n: any) => n.title === "Repair status updated"),
  );
});
test("staff and tenant invitations are email-bound, expire, and can only be accepted once", async () => {
  const email = `invited-${randomUUID()}@example.com`;
  const invited = await request(
    "POST",
    "/api/v1/team/invitations",
    { email, role: "staff", propertyIds: [fixtureId("property-0")] },
    owner,
  );
  assert.equal(invited.status, 200);
  const mail = (
    await pool.query(
      "SELECT body FROM delivery_logs WHERE destination=$1 ORDER BY created_at DESC LIMIT 1",
      [email],
    )
  ).rows[0];
  const token = mail.body.match(/[a-f0-9]{64}/)[0];
  const accept = {
    token,
    email,
    name: "Invited Staff",
    password: demoPassword,
  };
  assert.equal(
    (
      await request("POST", "/api/v1/identity/accept-invitation", {
        ...accept,
        email: "wrong@example.com",
      })
    ).status,
    400,
  );
  assert.equal(
    (await request("POST", "/api/v1/identity/accept-invitation", accept))
      .status,
    200,
  );
  assert.equal(
    (await request("POST", "/api/v1/identity/accept-invitation", accept))
      .status,
    400,
  );
  const session = await login(email);
  assert.equal(
    (await request("GET", "/api/v1/workspace", undefined, session)).body
      .properties.length,
    1,
  );
  const user = (
    await pool.query("SELECT id FROM users WHERE email=$1", [email])
  ).rows[0];
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/team/members/${user.id}`,
        { role: "staff", active: false, allProperties: false, propertyIds: [] },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (await request("GET", "/api/v1/workspace", undefined, session)).status,
    403,
  );
  const expiredEmail = `expired-${randomUUID()}@example.com`;
  await request(
    "POST",
    "/api/v1/team/invitations",
    { email: expiredEmail, role: "viewer", propertyIds: [] },
    owner,
  );
  const expiredMail = (
    await pool.query("SELECT body FROM delivery_logs WHERE destination=$1", [
      expiredEmail,
    ])
  ).rows[0];
  await pool.query(
    "UPDATE invitations SET expires_at=now()-interval '1 second' WHERE email=$1",
    [expiredEmail],
  );
  assert.equal(
    (
      await request("POST", "/api/v1/identity/accept-invitation", {
        ...accept,
        email: expiredEmail,
        token: expiredMail.body.match(/[a-f0-9]{64}/)[0],
      })
    ).status,
    400,
  );
});
test("recovery responses do not reveal account existence and reset codes revoke sessions once", async () => {
  const email = `reset-${randomUUID()}@example.com`;
  await request("POST", "/api/v1/auth/register", {
    name: "Reset Test",
    email,
    password: demoPassword,
    organization: "Reset Test",
  });
  const verify = (
    await pool.query("SELECT body FROM delivery_logs WHERE destination=$1", [
      email,
    ])
  ).rows[0].body.match(/[a-f0-9]{64}/)[0];
  await request("POST", "/api/v1/identity/verify", { token: verify });
  assert.equal(
    (await request("POST", "/api/v1/identity/verify", { token: verify }))
      .status,
    400,
  );
  const session = await login(email),
    known = await request("POST", "/api/v1/identity/recover", { email }),
    unknown = await request("POST", "/api/v1/identity/recover", {
      email: "not-a-user@example.com",
    });
  assert.deepEqual(known.body, unknown.body);
  const reset = (
    await pool.query(
      "SELECT body FROM delivery_logs WHERE destination=$1 AND title='Reset your Kwadra password'",
      [email],
    )
  ).rows[0].body.match(/[a-f0-9]{64}/)[0];
  assert.equal(
    (
      await request("POST", "/api/v1/identity/reset", {
        token: reset,
        password: "NewPassword!2026",
      })
    ).status,
    200,
  );
  assert.equal(
    (await request("GET", "/api/v1/auth/me", undefined, session)).status,
    401,
  );
  assert.equal(
    (
      await request("POST", "/api/v1/identity/reset", {
        token: reset,
        password: "NewPassword!2026",
      })
    ).status,
    400,
  );
});
test("draft leases reserve nothing until activation and renewals are separate valid terms", async () => {
  const { u, t } = await createPortfolio(),
    a = { ...leaseBody(u.id, [t.id]), status: "draft" },
    b = { ...leaseBody(u.id, [t.id]), status: "draft" };
  assert.equal((await request("POST", "/api/v1/leases", a, owner)).status, 200);
  assert.equal((await request("POST", "/api/v1/leases", b, owner)).status, 200);
  assert.equal(
    (await pool.query("SELECT occupancy FROM leases WHERE id=$1", [a.id]))
      .rows[0].occupancy,
    null,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/leases/${a.id}/activate`,
        { revision: 1 },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/leases/${b.id}/activate`,
        { revision: 1 },
        owner,
      )
    ).status,
    409,
  );
  const renewal = {
    ...leaseBody(u.id, [t.id]),
    start: "2027-01-01",
    end: "2027-12-31",
  };
  assert.equal(
    (await request("POST", `/api/v1/leases/${a.id}/renew`, renewal, owner))
      .status,
    200,
  );
  assert.equal(
    (
      await pool.query("SELECT renewal_of FROM leases WHERE id=$1", [
        renewal.id,
      ])
    ).rows[0].renewal_of,
    a.id,
  );
});
test("meter calculations round exact centavos, preserve baselines and issue each reading once", async () => {
  const m = await request(
    "POST",
    "/api/v1/utilities/meters",
    {
      unitId: fixtureId("unit-0-1"),
      kind: "water",
      label: "Exact rounding meter",
      rateCentavos: 325,
    },
    owner,
  );
  assert.equal(m.status, 200);
  const meterId = m.body.data.id;
  const baseReading = await request(
    "POST",
    "/api/v1/utilities/readings",
    { meterId, readOn: month + "-01", value: "100.0000" },
    owner,
  );
  assert.equal(
    (
      await request(
        "GET",
        `/api/v1/utilities/readings/${baseReading.body.data.id}/preview`,
        undefined,
        owner,
      )
    ).body.canInvoice,
    false,
  );
  const r = await request(
    "POST",
    "/api/v1/utilities/readings",
    { meterId, readOn: manilaToday(), value: "112.3456" },
    owner,
  );
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const id = r.body.data.id,
    preview = await request(
      "GET",
      `/api/v1/utilities/readings/${id}/preview`,
      undefined,
      owner,
    );
  assert.equal(preview.body.amount, 4012);
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/utilities/readings/${id}/issue`,
        { revision: 1, amount: 4013 },
        owner,
      )
    ).status,
    409,
  );
  const key = randomUUID(),
    issued = await request(
      "POST",
      `/api/v1/utilities/readings/${id}/issue`,
      { revision: 1, amount: 4012 },
      owner,
      key,
    );
  assert.equal(issued.status, 200);
  assert.deepEqual(
    (
      await request(
        "POST",
        `/api/v1/utilities/readings/${id}/issue`,
        { revision: 1, amount: 4012 },
        owner,
        key,
      )
    ).body,
    issued.body,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/utilities/readings/${id}/issue`,
        { revision: 2, amount: 4012 },
        owner,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await pool.query("SELECT amount,kind FROM invoices WHERE id=$1", [
        issued.body.data.invoiceId,
      ])
    ).rows[0].amount,
    "40.12",
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/utilities/readings/${baseReading.body.data.id}`,
        {
          revision: 1,
          value: "99",
          reason: "Changing an already-used baseline.",
        },
        owner,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "GET",
        `/api/v1/utilities/readings/${id}/preview`,
        undefined,
        other,
      )
    ).status,
    404,
  );
});
test("shared utility allocations reconcile and duplicate bill references are rejected", async () => {
  const { p, u, t } = await createPortfolio();
  await request("POST", "/api/v1/leases", leaseBody(u.id, [t.id]), owner);
  const second = unitBody(p.id);
  await request("POST", "/api/v1/units", second, owner);
  await request("POST", "/api/v1/leases", leaseBody(second.id, [t.id]), owner);
  const b = {
      propertyId: p.id,
      period: month,
      amount: 101,
      description: "WATER-BILL-TEST-001",
    },
    preview = await request(
      "POST",
      "/api/v1/utilities/shared/preview",
      b,
      owner,
    );
  assert.equal(preview.status, 200);
  assert.deepEqual(
    preview.body.allocations.map((a: any) => a.amount),
    [51, 50],
  );
  const issue = { ...b, expectedAllocations: preview.body.allocations },
    key = randomUUID();
  const first = await request(
    "POST",
    "/api/v1/utilities/shared/issue",
    issue,
    owner,
    key,
  );
  assert.equal(first.status, 200);
  assert.deepEqual(
    (await request("POST", "/api/v1/utilities/shared/issue", issue, owner, key))
      .body,
    first.body,
  );
  assert.equal(
    (await request("POST", "/api/v1/utilities/shared/issue", issue, owner))
      .status,
    409,
  );
  const turnover = await createPortfolio();
  for (const [start, end] of [
    [month + "-01", month + "-10"],
    [month + "-11", month + "-20"],
  ]) {
    await pool.query(
      `INSERT INTO leases(id,organization_id,unit_id,starts_on,ends_on,rent,due_day)
      VALUES($1,$2,$3,$4,$5,1000,5)`,
      [randomUUID(), org, turnover.u.id, start, end],
    );
  }
  const ambiguous = await request(
    "POST",
    "/api/v1/utilities/shared/preview",
    { ...b, propertyId: turnover.p.id },
    owner,
  );
  assert.equal(ambiguous.status, 409);
  assert.match(ambiguous.body.error.message, /turnover/);
});
test("announcements reach only linked tenants at the selected property", async () => {
  const r = await request(
    "POST",
    "/api/v1/announcements",
    {
      propertyId: fixtureId("property-0"),
      title: "Palm service notice",
      body: "Water inspection tomorrow morning.",
    },
    owner,
  );
  assert.equal(r.status, 200);
  assert.equal(r.body.data.recipients, 2);
  assert.ok(
    (
      await request("GET", "/api/v1/tenant/portal", undefined, tenantOne)
    ).body.announcements.some((a: any) => a.title === "Palm service notice"),
  );
  const target = (
    await pool.query(
      "SELECT recipient_id FROM notifications WHERE source_key=$1",
      ["announcement:" + r.body.data.id],
    )
  ).rows
    .map((r) => r.recipient_id)
    .sort();
  assert.deepEqual(
    target,
    [fixtureId("tenant-user"), fixtureId("tenant-user-2")].sort(),
  );
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/announcements",
        {
          propertyId: fixtureId("property-1"),
          title: "Wrong property",
          body: "Should fail.",
        },
        tenantOne,
      )
    ).status,
    403,
  );
});
test("move-out completion requires a scheduled handover and preserves issued charges", async () => {
  const requested = await request(
    "POST",
    "/api/v1/move-outs",
    {
      leaseId: fixtureId("lease-1"),
      requestedOn: manilaToday(),
      notes: "Development handover",
    },
    tenantTwo,
  );
  assert.equal(requested.status, 200);
  const id = requested.body.data.id;
  const checks = {
    keysReturned: true,
    inspectionComplete: true,
    recordsReviewed: true,
  };
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/move-outs/${id}`,
        { revision: 1, status: "completed", notes: "", checklist: checks },
        owner,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/move-outs/${id}`,
        {
          revision: 1,
          status: "scheduled",
          scheduledOn: manilaToday(),
          notes: "Inspection scheduled",
          checklist: { ...checks, keysReturned: false },
        },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/move-outs/${id}`,
        {
          revision: 2,
          status: "completed",
          notes: "Handover complete",
          checklist: checks,
        },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await pool.query("SELECT status FROM leases WHERE id=$1", [
        fixtureId("lease-1"),
      ])
    ).rows[0].status,
    "ended",
  );
  assert.equal(
    (
      await pool.query(
        "SELECT count(*)::int AS n FROM invoices WHERE lease_id=$1",
        [fixtureId("lease-1")],
      )
    ).rows[0].n,
    1,
  );
});
test("public search returns only approved fields and correct price, amenity and capacity filters", async () => {
  const r = await request("GET", "/api/v1/public/listings?pageSize=1");
  assert.equal(r.status, 200);
  assert.equal(r.body.total, 3);
  assert.equal(r.body.data.length, 1);
  const l = r.body.data[0];
  for (const field of [
    "organizationId",
    "unitId",
    "ownerEmail",
    "tenantIds",
    "address",
    "notes",
  ])
    assert.equal(l[field], undefined);
  assert.equal(l.publicEmail, "");
  assert.equal(l.latitude, null);
  assert.equal(
    (await request("GET", "/api/v1/public/listings?maxRent=700000")).body.total,
    1,
  );
  assert.equal(
    (await request("GET", "/api/v1/public/listings?capacity=3")).body.total,
    0,
  );
  assert.equal(
    (
      await request(
        "GET",
        "/api/v1/public/listings?amenity=" + fixtureId("amenity-Wi-Fi"),
      )
    ).body.total,
    3,
  );
  assert.equal(
    (await request("GET", "/api/v1/public/listings?sort=sql-injection")).status,
    422,
  );
});
let reviewedListing: string, reviewedListingRevision: number;
test("publisher verification and listing publication require an MFA moderator review", async () => {
  const p = propertyBody(),
    u = unitBody(p.id);
  await request("POST", "/api/v1/properties", p, other);
  await request("POST", "/api/v1/units", u, other);
  const submitted = await request(
    "POST",
    "/api/v1/publisher-verification",
    { file: pdf, notes: "Synthetic test publisher review evidence." },
    other,
  );
  assert.equal(submitted.status, 200, JSON.stringify(submitted.body));
  const review = await request(
    "PUT",
    `/api/v1/platform/publishers/${other.org}`,
    {
      revision: 1,
      status: "verified",
      reason: "Reviewed the supplied development evidence.",
      evidenceReviewed: true,
    },
    moderator,
  );
  assert.equal(review.status, 200, JSON.stringify(review.body));
  const id = randomUUID(),
    b = {
      id,
      unitId: u.id,
      title: "A reviewed integration rental",
      description:
        "A complete fictional listing for a development acceptance test.",
      locationLabel: "Test area, Cebu City",
      rent: 125050,
      moveInCost: 250100,
      revision: 0,
      amenityIds: [],
    };
  assert.equal(
    (await request("POST", "/api/v1/listings", b, other)).status,
    200,
  );
  const image = await readFile(
    path.join(root, "../apps/management/assets/images/studio.jpg"),
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/listings/${id}/photos`,
        {
          filename: "studio.jpg",
          mediaType: "image/jpeg",
          base64: image.toString("base64"),
        },
        other,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/listings/${id}/action`,
        { revision: 2, action: "submit" },
        other,
      )
    ).status,
    200,
  );
  assert.equal(
    (await request("GET", `/api/v1/public/listings/${id}`)).status,
    404,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/platform/listings/${id}`,
        {
          revision: 3,
          status: "approved",
          reason: "Reviewed listing content and evidence.",
        },
        other,
      )
    ).status,
    403,
  );
  const approved = await request(
    "PUT",
    `/api/v1/platform/listings/${id}`,
    {
      revision: 3,
      status: "approved",
      reason: "Reviewed listing content and evidence.",
    },
    moderator,
  );
  assert.equal(approved.status, 200, JSON.stringify(approved.body));
  assert.equal(
    (await request("GET", `/api/v1/public/listings/${id}`)).status,
    200,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/listings/${id}`,
        { ...b, revision: 4, title: "Updated reviewed rental" },
        other,
      )
    ).status,
    200,
  );
  assert.equal(
    (await request("GET", `/api/v1/public/listings/${id}`)).status,
    404,
  );
  await request(
    "POST",
    `/api/v1/listings/${id}/action`,
    { revision: 5, action: "submit" },
    other,
  );
  await request(
    "PUT",
    `/api/v1/platform/listings/${id}`,
    {
      revision: 6,
      status: "approved",
      reason: "Rechecked the changed public content.",
    },
    moderator,
  );
  reviewedListing = id;
  reviewedListingRevision = 7;
});
test("reports, takedown, appeal and restoration preserve moderation history", async () => {
  const id = reviewedListing;
  assert.ok(id);
  assert.equal(
    (
      await request("POST", `/api/v1/public/listings/${id}/report`, {
        reason: "This is a synthetic report requiring review.",
        email: "reporter@example.com",
      })
    ).status,
    200,
  );
  const take = await request(
    "PUT",
    `/api/v1/platform/listings/${id}`,
    {
      revision: reviewedListingRevision,
      status: "unpublished",
      reason: "Temporary development takedown for a report review.",
    },
    moderator,
  );
  assert.equal(take.status, 200);
  assert.equal(
    (await request("GET", `/api/v1/public/listings/${id}`)).status,
    404,
  );
  const c = (
    await pool.query(
      "SELECT id FROM moderation_cases WHERE listing_id=$1 ORDER BY created_at DESC LIMIT 1",
      [id],
    )
  ).rows[0];
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/moderation/cases/${c.id}/appeal`,
        { reason: "The reported concern has been addressed in this test." },
        other,
      )
    ).status,
    200,
  );
  assert.equal(
    (await request("GET", `/api/v1/public/listings/${id}`)).status,
    404,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/platform/listings/${id}`,
        {
          revision: 8,
          status: "approved",
          reason: "Appeal evidence reviewed and publication restored.",
        },
        moderator,
      )
    ).status,
    200,
  );
  const events = (
    await pool.query("SELECT detail FROM moderation_events WHERE case_id=$1", [
      c.id,
    ])
  ).rows;
  assert.ok(events.some((e) => e.detail.startsWith("Appeal:")));
  assert.ok(events.length >= 3);
});
test("inquiry tracking is secret-bound and viewing proposals require consistent confirmation", async () => {
  const id = reviewedListing,
    time = new Date(Date.now() + 2 * 86400000).toISOString();
  const r = await request("POST", `/api/v1/public/listings/${id}/inquiries`, {
    name: "Test Seeker",
    email: "seeker@example.com",
    phone: "09170000000",
    message: "I would like to arrange a viewing for this rental.",
    viewingAt: time,
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  const inquiryId = r.body.id,
    token = r.body.trackingToken,
    headers = { "X-Inquiry-Token": token };
  assert.equal(
    (await request("GET", `/api/v1/public/inquiries/${inquiryId}`)).status,
    404,
  );
  const tracked = await request(
    "GET",
    `/api/v1/public/inquiries/${inquiryId}`,
    undefined,
    undefined,
    undefined,
    headers,
  );
  assert.equal(tracked.status, 200);
  assert.equal(tracked.body.messages.length, 1);
  const v = tracked.body.viewings[0];
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/inquiries/${inquiryId}/reply`,
        { revision: 1, message: "A viewing is possible." },
        owner,
      )
    ).status,
    404,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/inquiries/${inquiryId}/reply`,
        { revision: 1, message: "We can arrange a viewing." },
        other,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/viewings/${v.id}`,
        {
          revision: 1,
          status: "proposed",
          scheduledAt: new Date(Date.now() + 3 * 86400000).toISOString(),
        },
        other,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/public/inquiries/${inquiryId}/viewings`,
        { id: v.id, revision: 2, action: "confirm" },
        undefined,
        undefined,
        headers,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/public/inquiries/${inquiryId}/viewings`,
        { id: v.id, revision: 3, action: "confirm" },
        undefined,
        undefined,
        headers,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/inquiries/${inquiryId}/convert`,
        { revision: 2 },
        other,
      )
    ).status,
    200,
  );
  assert.notEqual(
    (
      await pool.query("SELECT tracking_hash FROM inquiries WHERE id=$1", [
        inquiryId,
      ])
    ).rows[0].tracking_hash,
    token,
  );
});
test("reserved units disappear immediately from discovery, photos and indexable pages", async () => {
  const id = fixtureId("listing-0"),
    before = await request("GET", `/api/v1/public/listings/${id}`);
  assert.equal(before.status, 200);
  const photo = before.body.data.photos[0];
  const lease = leaseBody(fixtureId("unit-0-7"), [fixtureId("tenant-0")]);
  assert.equal(
    (await request("POST", "/api/v1/leases", lease, owner)).status,
    200,
  );
  assert.equal(
    (await request("GET", `/api/v1/public/listings/${id}`)).status,
    404,
  );
  assert.equal(
    (await fetch(base + `/api/v1/public/photos/${photo}`)).status,
    404,
  );
  const unavailable = await fetch(base + `/marketplace/listings/${id}`);
  assert.equal(unavailable.status, 404);
  const sitemap = await (await fetch(base + "/sitemap.xml")).text();
  assert.ok(!sitemap.includes(id));
  const html = await (await fetch(base + "/marketplace")).text();
  assert.ok(html.includes("<h1>"));
  assert.ok(!html.includes("Isabel Reyes"));
  assert.ok(!html.includes("password_hash"));
  const detail = await (
    await fetch(base + `/marketplace/listings/${reviewedListing}`)
  ).text();
  assert.ok(detail.includes("application/ld+json"));
  assert.ok(detail.includes('rel="canonical"'));
});
test("billing and delivery jobs are idempotent and a mail failure does not corrupt charges", async () => {
  const failed = await runJobs(pool, async () => {
    throw new Error("Synthetic transport failure");
  });
  assert.ok(failed.failed > 0);
  const count = Number(
    (await pool.query("SELECT count(*) AS n FROM invoices")).rows[0].n,
  );
  await pool.query(
    "UPDATE delivery_logs SET status='pending',next_attempt_at=now(),attempts=0 WHERE status='failed'",
  );
  const success = await runJobs(pool, async () => {});
  assert.ok(success.delivered > 0);
  assert.equal(success.invoices, 0);
  assert.equal(
    Number((await pool.query("SELECT count(*) AS n FROM invoices")).rows[0].n),
    count,
  );
  const duplicates = await pool.query(
    "SELECT lease_id,period FROM invoices WHERE kind='rent' GROUP BY organization_id,lease_id,period HAVING count(*)>1",
  );
  assert.equal(duplicates.rowCount, 0);
});
test("account suspension revokes publisher sessions and removes public listings", async () => {
  const suspended = await request(
    "POST",
    "/api/v1/platform/accounts",
    {
      userId: fixtureId("other-owner"),
      disabled: true,
      reason: "Synthetic abuse-control acceptance test.",
    },
    moderator,
  );
  assert.equal(suspended.status, 200);
  assert.equal(
    (await request("GET", "/api/v1/auth/me", undefined, other)).status,
    401,
  );
  assert.equal(
    (await request("GET", `/api/v1/public/listings/${reviewedListing}`)).status,
    404,
  );
  for (const table of [
    "payments",
    "payment_allocations",
    "payment_proofs",
    "payment_reversals",
    "receipts",
    "deposit_transactions",
    "provider_events",
    "subscriptions",
  ])
    assert.equal(
      (await pool.query(`SELECT count(*)::int AS n FROM ${table}`)).rows[0].n,
      0,
    );
});

let seeker: Session,
  secondSeeker: Session,
  seekerUser: string,
  mobileListing: string,
  accountInquiry: string;
const seekerEmail = `mobile-${randomUUID()}@example.com`;
test("mobile marketplace is public for browsing and requires sessions for personal actions", async () => {
  assert.equal((await request("GET", "/api/v1/public/listings")).status, 200);
  for (const path of [
    "/api/v1/marketplace/saved",
    "/api/v1/marketplace/inquiries",
  ])
    assert.equal((await request("GET", path)).status, 401);
  assert.equal(
    (
      await request(
        "POST",
        `/api/v1/marketplace/listings/${fixtureId("public-listing-0")}/inquiries`,
        { message: "Unauthorized inquiry attempt." },
      )
    ).status,
    401,
  );
});
test("renter registration verifies email without creating a landlord organization", async () => {
  const created = await request("POST", "/api/v1/auth/register-seeker", {
    name: "Mobile Seeker",
    email: seekerEmail,
    password: demoPassword,
  });
  assert.equal(created.status, 201, JSON.stringify(created.body));
  const user = (
    await pool.query("SELECT * FROM users WHERE email=$1", [seekerEmail])
  ).rows[0];
  seekerUser = user.id;
  assert.equal(user.marketplace_account, true);
  assert.equal(
    (
      await pool.query(
        "SELECT count(*)::int AS n FROM memberships WHERE user_id=$1",
        [user.id],
      )
    ).rows[0].n,
    0,
  );
  assert.equal(
    (
      await request("POST", "/api/v1/auth/login", {
        email: seekerEmail,
        password: demoPassword,
        client: "native",
      })
    ).body.error.code,
    "EMAIL_UNVERIFIED",
  );
  const mail = (
    await pool.query(
      "SELECT * FROM delivery_logs WHERE recipient_id=$1 ORDER BY created_at DESC LIMIT 1",
      [user.id],
    )
  ).rows[0];
  assert.equal(mail.organization_id, null);
  const token = mail.body.match(/[a-f0-9]{64}/)[0];
  assert.equal(
    (await request("POST", "/api/v1/identity/verify", { token })).status,
    200,
  );
  seeker = await login(seekerEmail);
  secondSeeker = await login("renter@example.com");
  const me = await request("GET", "/api/v1/auth/me", undefined, seeker);
  assert.equal(me.status, 200);
  assert.deepEqual(me.body.organizations, []);
  assert.equal(
    (await request("GET", "/api/v1/workspace", undefined, seeker)).status,
    400,
  );
  assert.equal(
    (
      await request(
        "GET",
        "/api/v1/workspace",
        undefined,
        seeker,
        randomUUID(),
        { "X-Organization-Id": org },
      )
    ).status,
    403,
  );
});
test("renter cookie sessions restore and protect writes without organization headers", async () => {
  const signed = await request("POST", "/api/v1/auth/login", {
    email: seekerEmail,
    password: demoPassword,
    client: "web",
  });
  const cookie = signed.headers.get("set-cookie")!.split(";")[0],
    headers = { Cookie: cookie };
  const me = await request(
    "GET",
    "/api/v1/auth/me",
    undefined,
    undefined,
    randomUUID(),
    headers,
  );
  assert.equal(me.status, 200);
  assert.deepEqual(me.body.organizations, []);
  const found = await request("GET", "/api/v1/public/listings");
  mobileListing = found.body.data[0].id;
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/marketplace/saved/${mobileListing}`,
        { saved: true },
        undefined,
        randomUUID(),
        headers,
      )
    ).body.error.code,
    "CSRF_FAILED",
  );
  const logout = await request(
    "POST",
    "/api/v1/auth/logout",
    {},
    undefined,
    randomUUID(),
    { ...headers, "X-CSRF-Token": me.body.csrfToken },
  );
  assert.equal(logout.status, 200);
  assert.equal(
    (
      await request(
        "GET",
        "/api/v1/auth/me",
        undefined,
        undefined,
        randomUUID(),
        headers,
      )
    ).status,
    401,
  );
});
test("account saved rentals are isolated, retryable and revalidated against availability", async () => {
  const key = randomUUID(),
    path = `/api/v1/marketplace/saved/${mobileListing}`;
  const first = await request("PUT", path, { saved: true }, seeker, key);
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.deepEqual(
    (await request("PUT", path, { saved: true }, seeker, key)).body,
    first.body,
  );
  assert.equal(
    (await request("PUT", path, { saved: false }, seeker, key)).status,
    409,
  );
  assert.equal(
    (await request("GET", "/api/v1/marketplace/saved", undefined, seeker)).body
      .data.length,
    1,
  );
  assert.equal(
    (await request("GET", "/api/v1/marketplace/saved", undefined, secondSeeker))
      .body.data.length,
    0,
  );
  const unit = (
    await pool.query("SELECT unit_id FROM listings WHERE id=$1", [
      mobileListing,
    ])
  ).rows[0].unit_id;
  await pool.query("UPDATE units SET maintenance=true WHERE id=$1", [unit]);
  try {
    const hidden = await request(
      "GET",
      "/api/v1/marketplace/saved",
      undefined,
      seeker,
    );
    assert.equal(hidden.body.data.length, 0);
    assert.equal(hidden.body.unavailableCount, 1);
    assert.equal(
      (await request("PUT", path, { saved: true }, secondSeeker)).status,
      404,
    );
    assert.equal(
      (await request("PUT", path, { saved: false }, seeker)).status,
      200,
    );
  } finally {
    await pool.query("UPDATE units SET maintenance=false WHERE id=$1", [unit]);
  }
});
test("account inquiries bind verified identity and cannot be read through another account or a tracking link", async () => {
  const path = `/api/v1/marketplace/listings/${mobileListing}/inquiries`,
    key = randomUUID(),
    body = {
      message: "A synthetic inquiry from the native marketplace.",
      phone: "09170000000",
    };
  assert.equal(
    (
      await request(
        "POST",
        path,
        { ...body, email: "forged@example.com" },
        seeker,
      )
    ).status,
    422,
  );
  const created = await request("POST", path, body, seeker, key);
  assert.equal(created.status, 200, JSON.stringify(created.body));
  accountInquiry = created.body.data.id;
  assert.equal(created.body.data.trackingToken, undefined);
  assert.deepEqual(
    (await request("POST", path, body, seeker, key)).body,
    created.body,
  );
  const row = (
    await pool.query("SELECT * FROM inquiries WHERE id=$1", [accountInquiry])
  ).rows[0];
  assert.equal(row.seeker_id, seekerUser);
  assert.equal(row.email, seekerEmail);
  assert.equal(row.name, "Mobile Seeker");
  assert.equal(row.tracking_hash, null);
  const mine = await request(
    "GET",
    `/api/v1/marketplace/inquiries/${accountInquiry}`,
    undefined,
    seeker,
  );
  assert.equal(mine.status, 200);
  assert.equal(
    (
      await request(
        "GET",
        `/api/v1/marketplace/inquiries/${accountInquiry}`,
        undefined,
        secondSeeker,
        randomUUID(),
        { "X-Organization-Id": org },
      )
    ).status,
    404,
  );
  assert.equal(
    (
      await request(
        "GET",
        `/api/v1/public/inquiries/${accountInquiry}`,
        undefined,
        undefined,
        randomUUID(),
        { "X-Inquiry-Token": "a".repeat(64) },
      )
    ).status,
    404,
  );
  assert.equal(
    (await request("GET", "/api/v1/marketplace/inquiries", undefined, seeker))
      .body.data[0].id,
    accountInquiry,
  );
  assert.equal(
    (
      await request(
        "GET",
        "/api/v1/marketplace/inquiries",
        undefined,
        secondSeeker,
      )
    ).body.data.length,
    0,
  );
});
test("account conversations support landlord replies and idempotent seeker messages", async () => {
  const reply = await request(
    "POST",
    `/api/v1/inquiries/${accountInquiry}/reply`,
    { revision: 1, message: "Please let us know a viewing time." },
    owner,
  );
  assert.equal(reply.status, 200);
  const path = `/api/v1/marketplace/inquiries/${accountInquiry}/messages`,
    body = { message: "Would tomorrow work for a viewing?" },
    key = randomUUID();
  assert.equal((await request("POST", path, body, secondSeeker)).status, 404);
  const sent = await request("POST", path, body, seeker, key);
  assert.equal(sent.status, 200);
  assert.deepEqual(
    (await request("POST", path, body, seeker, key)).body,
    sent.body,
  );
  const thread = await request(
    "GET",
    `/api/v1/marketplace/inquiries/${accountInquiry}`,
    undefined,
    seeker,
  );
  assert.equal(thread.body.messages.length, 3);
  assert.ok(thread.body.messages.some((m: any) => m.sender === "landlord"));
});
test("account viewing proposals preserve ownership, confirmation and revision checks", async () => {
  const path = `/api/v1/marketplace/inquiries/${accountInquiry}/viewings`,
    when = new Date(Date.now() + 2 * 86400000).toISOString(),
    key = randomUUID();
  const created = await request(
    "POST",
    path,
    { action: "request", scheduledAt: when },
    seeker,
    key,
  );
  assert.equal(created.status, 200);
  assert.deepEqual(
    (
      await request(
        "POST",
        path,
        { action: "request", scheduledAt: when },
        seeker,
        key,
      )
    ).body,
    created.body,
  );
  const id = created.body.data.id;
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/viewings/${id}`,
        {
          revision: 1,
          status: "proposed",
          scheduledAt: new Date(Date.now() + 3 * 86400000).toISOString(),
        },
        owner,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "POST",
        path,
        { action: "confirm", id, revision: 2 },
        secondSeeker,
      )
    ).status,
    404,
  );
  assert.equal(
    (
      await request(
        "POST",
        path,
        { action: "confirm", id, revision: 2 },
        seeker,
      )
    ).status,
    200,
  );
  assert.equal(
    (await request("POST", path, { action: "cancel", id, revision: 2 }, seeker))
      .status,
    409,
  );
  assert.equal(
    (await request("POST", path, { action: "cancel", id, revision: 3 }, seeker))
      .status,
    200,
  );
});
test("renter accounts can create their own landlord workspace without losing conversations", async () => {
  const created = await request(
    "POST",
    "/api/v1/marketplace/organization",
    { name: "My new rentals" },
    seeker,
  );
  assert.equal(created.status, 200);
  const organizationId = created.body.data.organizationId;
  assert.equal(
    (
      await request("GET", "/api/v1/workspace", undefined, {
        ...seeker,
        org: organizationId,
      })
    ).status,
    200,
  );
  assert.equal(
    (await request("GET", "/api/v1/workspace", undefined, { ...seeker, org }))
      .status,
    403,
  );
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/marketplace/organization",
        { name: "Duplicate workspace" },
        seeker,
      )
    ).status,
    409,
  );
  assert.equal(
    (
      await request(
        "GET",
        `/api/v1/marketplace/inquiries/${accountInquiry}`,
        undefined,
        seeker,
      )
    ).status,
    200,
  );
});
test("password recovery supports renters with no organization and revokes their sessions", async () => {
  assert.equal(
    (
      await request("POST", "/api/v1/identity/recover", {
        email: "renter@example.com",
      })
    ).status,
    200,
  );
  const mail = (
    await pool.query(
      "SELECT * FROM delivery_logs WHERE destination='renter@example.com' AND title='Reset your Kwadra password' ORDER BY created_at DESC LIMIT 1",
    )
  ).rows[0];
  assert.equal(mail.organization_id, null);
  const token = mail.body.match(/[a-f0-9]{64}/)[0];
  assert.equal(
    (
      await request("POST", "/api/v1/identity/reset", {
        token,
        password: demoPassword + "!",
      })
    ).status,
    200,
  );
  assert.equal(
    (
      await request(
        "GET",
        "/api/v1/marketplace/inquiries",
        undefined,
        secondSeeker,
      )
    ).status,
    401,
  );
  assert.equal(
    (
      await request("POST", "/api/v1/auth/login", {
        email: "renter@example.com",
        password: demoPassword + "!",
        client: "native",
      })
    ).status,
    200,
  );
  for (const table of [
    "payments",
    "payment_proofs",
    "receipts",
    "deposit_transactions",
    "subscriptions",
  ])
    assert.equal(
      (await pool.query(`SELECT count(*)::int AS n FROM ${table}`)).rows[0].n,
      0,
    );
});

test("personal marketplace access survives staff revocation while suspension ends all access", async () => {
  assert.equal(
    (
      await request(
        "PUT",
        `/api/v1/marketplace/saved/${mobileListing}`,
        { saved: true },
        staff,
      )
    ).status,
    200,
  );
  const formerStaff = await login("staff@example.com");
  assert.equal(formerStaff.org, undefined);
  assert.equal(
    (
      await request("GET", "/api/v1/workspace", undefined, {
        ...formerStaff,
        org,
      })
    ).status,
    403,
  );
  assert.equal(
    (await request("GET", "/api/v1/marketplace/saved", undefined, formerStaff))
      .body.data.length,
    1,
  );
  const report = await request(
    "POST",
    `/api/v1/marketplace/listings/${mobileListing}/report`,
    { reason: "Synthetic native marketplace report." },
    seeker,
  );
  assert.equal(report.status, 200);
  assert.equal(
    (
      await request(
        "POST",
        "/api/v1/platform/accounts",
        {
          userId: seekerUser,
          disabled: true,
          reason: "Synthetic account access acceptance test.",
        },
        moderator,
      )
    ).status,
    200,
  );
  assert.equal(
    (await request("GET", "/api/v1/marketplace/inquiries", undefined, seeker))
      .status,
    401,
  );
});
