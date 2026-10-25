import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import net from "node:net";
import type { Server } from "node:http";
import type pg from "pg";
import path from "node:path";
import { localPostgres } from "../src/local-postgres.js";
import { createPool, migrate, transaction } from "../src/db.js";
import { createApp } from "../src/app.js";
import { root } from "../src/config.js";
import { seed, demoPassword, fixtureId } from "../src/seed.js";
import { hashPassword, hashToken } from "../src/auth.js";
import { type GoogleIdentity } from "../src/google-auth.js";
import { notify, deliverMail } from "../src/mail.js";
import { encryptSecret, totp } from "../src/security.js";
import { demoMfaSecret } from "../src/phase-seed.js";
import { ApiError } from "../src/errors.js";
import { readFile } from "node:fs/promises";

let pool: pg.Pool,
  server: Server,
  base: string,
  cluster: Awaited<ReturnType<typeof localPostgres>>["cluster"];
let passwordHash: string;
const identities = new Map<string, GoogleIdentity>();
async function port() {
  const s = net.createServer();
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));
  const p = (s.address() as net.AddressInfo).port;
  await new Promise<void>((r) => s.close(() => r()));
  return p;
}
before(
  async () => {
    const local = await localPostgres({
      directory: path.join(root, ".local", "accounts-tests", randomUUID()),
      port: await port(),
    });
    cluster = local.cluster;
    pool = createPool(local.url);
    await migrate(pool);
    await seed(pool);
    passwordHash = await hashPassword(demoPassword);
    server = createApp(pool, {
      testing: true,
      googleVerifier: async (token) => {
        const p = identities.get(token);
        if (!p)
          throw new ApiError(401, "Invalid Google token", "GOOGLE_INVALID");
        return p;
      },
    }).listen(0, "127.0.0.1");
    await new Promise<void>((r) => server.once("listening", r));
    base = `http://127.0.0.1:${(server.address() as net.AddressInfo).port}`;
  },
  { timeout: 120000 },
);
after(async () => {
  if (server) {
    server.closeAllConnections();
    await new Promise<void>((r) => server.close(() => r()));
  }
  await pool?.end();
  await cluster?.stop();
});
async function request(
  method: string,
  route: string,
  body?: unknown,
  token?: string,
  headers: Record<string, string> = {},
) {
  const r = await fetch(base + "/api/v1" + route, {
    method,
    headers: {
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...(token ? { Authorization: "Bearer " + token } : {}),
      "Idempotency-Key": randomUUID(),
      ...headers,
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  return {
    status: r.status,
    body: (await r.json()) as any,
    headers: r.headers,
  };
}
async function account() {
  const id = randomUUID(),
    email = id + "@example.com";
  await pool.query(
    "INSERT INTO users(id,name,email,password_hash,email_verified_at,marketplace_account) VALUES($1,'Test renter',$2,$3,now(),true)",
    [id, email, passwordHash],
  );
  return { id, email };
}
async function login(email: string, client = "native") {
  const r = await request("POST", "/auth/login", {
    email,
    password: demoPassword,
    client,
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r;
}
function google(identity: Partial<GoogleIdentity> = {}) {
  const token = "google-test-" + randomUUID();
  identities.set(token, {
    sub: randomUUID(),
    email: randomUUID() + "@gmail.com",
    email_verified: true,
    name: "Google renter",
    ...identity,
  });
  return token;
}

test("native sessions rotate after expiry and replay revokes the complete family", async () => {
  const a = await account(),
    first = await login(a.email);
  assert.match(first.body.refreshToken, /^[a-f0-9]{64}$/);
  await pool.query(
    "UPDATE sessions SET expires_at=now()-interval '1 second' WHERE token_hash=$1",
    [hashToken(first.body.token)],
  );
  assert.equal(
    (await request("GET", "/auth/me", undefined, first.body.token)).status,
    401,
  );
  const rotated = await request("POST", "/auth/refresh", {
    refreshToken: first.body.refreshToken,
  });
  assert.equal(rotated.status, 200);
  assert.notEqual(rotated.body.refreshToken, first.body.refreshToken);
  assert.equal(
    (await request("GET", "/auth/me", undefined, rotated.body.token)).status,
    200,
  );
  assert.equal(
    (
      await request("POST", "/auth/refresh", {
        refreshToken: first.body.refreshToken,
      })
    ).status,
    401,
  );
  assert.equal(
    (await request("GET", "/auth/me", undefined, rotated.body.token)).status,
    401,
  );
  assert.equal(
    (
      await request("POST", "/auth/refresh", {
        refreshToken: rotated.body.refreshToken,
      })
    ).status,
    401,
  );
});
test("concurrent reuse of a refresh credential cannot leave a valid replayed family", async () => {
  const a = await account(),
    first = await login(a.email);
  const responses = await Promise.all(
    [1, 2].map(() =>
      request("POST", "/auth/refresh", {
        refreshToken: first.body.refreshToken,
      }),
    ),
  );
  assert.deepEqual(responses.map((r) => r.status).sort(), [200, 401]);
  const accepted = responses.find((r) => r.status === 200)!;
  assert.equal(
    (await request("GET", "/auth/me", undefined, accepted.body.token)).status,
    401,
  );
});
test("logout, password changes and suspension revoke remembered devices", async () => {
  for (const action of ["logout", "password", "suspend"]) {
    const a = await account(),
      s = await login(a.email);
    if (action === "logout")
      assert.equal(
        (await request("POST", "/auth/logout", {}, s.body.token)).status,
        200,
      );
    else if (action === "password")
      await pool.query("UPDATE users SET password_hash=$2 WHERE id=$1", [
        a.id,
        await hashPassword("ChangedPassword!2026"),
      ]);
    else await pool.query("UPDATE users SET disabled=true WHERE id=$1", [a.id]);
    assert.equal(
      (
        await request("POST", "/auth/refresh", {
          refreshToken: s.body.refreshToken,
        })
      ).status,
      401,
    );
  }
});
test("browser login keeps credentials in HttpOnly cookies and enforces CSRF on personal writes", async () => {
  const a = await account(),
    s = await login(a.email, "web");
  assert.equal(s.body.token, undefined);
  assert.equal(s.body.refreshToken, undefined);
  const cookie = s.headers.get("set-cookie")!;
  assert.match(cookie, /HttpOnly/i);
  const headers = { Cookie: cookie.split(";")[0] };
  assert.equal(
    (
      await request(
        "PUT",
        "/account/notification-preferences",
        { inApp: true },
        undefined,
        headers,
      )
    ).status,
    403,
  );
  assert.equal(
    (
      await request(
        "PUT",
        "/account/notification-preferences",
        { inApp: true },
        undefined,
        { ...headers, "X-CSRF-Token": s.body.csrfToken },
      )
    ).status,
    200,
  );
});
test("verification resend is generic, rate bounded and replaces older codes", async () => {
  const a = await account();
  await pool.query("UPDATE users SET email_verified_at=NULL WHERE id=$1", [
    a.id,
  ]);
  const old = "a".repeat(64);
  await pool.query(
    "INSERT INTO identity_tokens(token_hash,user_id,purpose,expires_at,created_at) VALUES($1,$2,'verify_email',now()+interval '1 day',now()-interval '2 minutes')",
    [hashToken(old), a.id],
  );
  const existing = await request("POST", "/identity/resend-verification", {
    email: a.email,
  });
  const unknown = await request("POST", "/identity/resend-verification", {
    email: randomUUID() + "@example.com",
  });
  assert.deepEqual(existing.body, unknown.body);
  await request("POST", "/identity/resend-verification", { email: a.email });
  const mails = (
    await pool.query(
      "SELECT body FROM delivery_logs WHERE recipient_id=$1 AND title='Verify your Kwadra email'",
      [a.id],
    )
  ).rows;
  assert.equal(mails.length, 1);
  assert.equal(
    (await request("POST", "/identity/verify", { token: old })).status,
    400,
  );
  const token = mails[0].body.match(/[a-f0-9]{64}/)[0];
  assert.equal(
    (await request("POST", "/identity/verify", { token })).status,
    200,
  );
  assert.equal(
    (await request("POST", "/identity/verify", { token })).status,
    400,
  );
  await login(a.email);
});
test("Google creates a personal account and keys later sign-ins by subject", async () => {
  const token = google(),
    first = await request("POST", "/auth/google", {
      idToken: token,
      client: "native",
    });
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.deepEqual(first.body.organizations, []);
  assert.equal(first.body.user.marketplaceAccount, true);
  identities.get(token)!.email = randomUUID() + "@gmail.com";
  const again = await request("POST", "/auth/google", {
    idToken: token,
    client: "native",
  });
  assert.equal(again.body.user.id, first.body.user.id);
  assert.equal(
    (await request("POST", "/auth/google", { idToken: "invalid-credential" }))
      .status,
    401,
  );
});
test("Google never silently merges an existing email; linking requires its current password", async () => {
  const a = await account(),
    token = google({ email: a.email });
  assert.equal(
    (
      await request("POST", "/auth/google", {
        idToken: token,
        client: "native",
      })
    ).body.error.code,
    "ACCOUNT_LINK_REQUIRED",
  );
  const s = await login(a.email);
  assert.equal(
    (
      await request(
        "POST",
        "/auth/google/link",
        { idToken: token, password: "incorrect" },
        s.body.token,
      )
    ).status,
    403,
  );
  assert.equal(
    (
      await request(
        "POST",
        "/auth/google/link",
        { idToken: token, password: demoPassword },
        s.body.token,
      )
    ).status,
    200,
  );
  assert.equal(
    (
      await request("POST", "/auth/google", {
        idToken: token,
        client: "native",
      })
    ).body.user.id,
    a.id,
  );
});
test("non-authoritative Google email still requires Kwadra verification", async () => {
  const token = google({ email: randomUUID() + "@example.com" });
  const r = await request("POST", "/auth/google", {
    idToken: token,
    client: "native",
  });
  assert.equal(r.body.error.code, "EMAIL_UNVERIFIED");
  const user = (
    await pool.query("SELECT id,email_verified_at FROM users WHERE email=$1", [
      identities.get(token)!.email,
    ])
  ).rows[0];
  assert.equal(user.email_verified_at, null);
  assert.equal(
    (
      await pool.query(
        "SELECT count(*)::int n FROM delivery_logs WHERE recipient_id=$1",
        [user.id],
      )
    ).rows[0].n,
    1,
  );
});
test("Google cannot bypass administrator MFA or extend its remembered session beyond 12 hours", async () => {
  const a = await account(),
    token = google({ email: a.email });
  await pool.query(
    "UPDATE users SET platform_admin=true,mfa_secret=$2 WHERE id=$1",
    [a.id, await encryptSecret(demoMfaSecret)],
  );
  await pool.query(
    "INSERT INTO external_identities(provider,subject,user_id) VALUES('google',$1,$2)",
    [identities.get(token)!.sub, a.id],
  );
  assert.equal(
    (
      await request("POST", "/auth/google", {
        idToken: token,
        client: "native",
      })
    ).body.error.code,
    "MFA_REQUIRED",
  );
  const r = await request("POST", "/auth/google", {
    idToken: token,
    client: "native",
    mfaCode: totp(demoMfaSecret),
  });
  assert.equal(r.status, 200);
  const remaining = (
    await pool.query(
      "SELECT extract(epoch FROM (expires_at-now()))::int seconds FROM native_session_families WHERE user_id=$1",
      [a.id],
    )
  ).rows[0].seconds;
  assert.ok(remaining <= 43200 && remaining > 43000);
});
test("account notifications enforce recipient and membership scope", async () => {
  const a = await account(),
    b = await account(),
    s = await login(a.email),
    t = await login(b.email);
  await transaction(pool, (db) =>
    notify(
      db,
      null,
      a.id,
      "Personal update",
      "Only for A",
      "personal-" + randomUUID(),
    ),
  );
  await transaction(pool, (db) =>
    notify(
      db,
      fixtureId("org"),
      a.id,
      "Private org update",
      "Must be hidden",
      "org-" + randomUUID(),
    ),
  );
  const mine = await request(
    "GET",
    "/account/notifications",
    undefined,
    s.body.token,
  );
  assert.equal(mine.body.notifications.length, 1);
  assert.equal(mine.body.unread, 1);
  assert.equal(
    (await request("GET", "/account/notifications", undefined, t.body.token))
      .body.notifications.length,
    0,
  );
  const id = mine.body.notifications[0].id;
  await request(
    "POST",
    "/account/notifications/read",
    { ids: [id] },
    t.body.token,
  );
  assert.equal(
    (await request("GET", "/account/notifications", undefined, s.body.token))
      .body.unread,
    1,
  );
  await request(
    "POST",
    "/account/notifications/read",
    { ids: [id] },
    s.body.token,
  );
  assert.equal(
    (await request("GET", "/account/notifications", undefined, s.body.token))
      .body.unread,
    0,
  );
});
test(
  "foreground events are private invalidations and close when the session is suspended",
  { timeout: 30000 },
  async () => {
    const a = await account(),
      b = await account(),
      s = await login(a.email),
      abort = new AbortController();
    const response = await fetch(
      base + "/api/v1/account/notifications/events",
      {
        headers: { Authorization: "Bearer " + s.body.token },
        signal: abort.signal,
      },
    );
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type")!, /text\/event-stream/);
    const reader = response.body!.getReader(),
      decoder = new TextDecoder();
    try {
      assert.match(decoder.decode((await reader.read()).value), /changed/);
      await transaction(pool, (db) =>
        notify(
          db,
          null,
          b.id,
          "Private other-account title",
          "Never sent over this stream",
          randomUUID(),
        ),
      );
      const unrelated = decoder.decode((await reader.read()).value);
      assert.match(unrelated, /heartbeat/);
      assert.doesNotMatch(unrelated, /changed|Private other/);
      await transaction(pool, (db) =>
        notify(
          db,
          null,
          a.id,
          "Private own title",
          "Body remains in authenticated inbox",
          randomUUID(),
        ),
      );
      const own = decoder.decode((await reader.read()).value);
      assert.match(own, /changed/);
      assert.doesNotMatch(own, /Private own|Body remains/);
      await pool.query("UPDATE users SET disabled=true WHERE id=$1", [a.id]);
      assert.match(decoder.decode((await reader.read()).value), /expired/);
    } finally {
      abort.abort();
      await reader.cancel().catch(() => {});
    }
  },
);
test("landlord replies and viewing decisions reach the renter notification inbox", async () => {
  const a = await account(),
    s = await login(a.email),
    owner = await login("alex@example.com");
  const listing = (
    await pool.query(
      "SELECT id FROM listings WHERE organization_id=$1 AND status='approved' LIMIT 1",
      [fixtureId("org")],
    )
  ).rows[0];
  assert.ok(listing);
  const created = await request(
    "POST",
    `/marketplace/listings/${listing.id}/inquiries`,
    { message: "Synthetic notification integration inquiry." },
    s.body.token,
  );
  assert.equal(created.status, 200, JSON.stringify(created.body));
  const inquiryId = created.body.data.id;
  const reply = await request(
    "POST",
    `/inquiries/${inquiryId}/reply`,
    {
      revision: 1,
      message: "Synthetic landlord reply for inbox verification.",
    },
    owner.body.token,
    { "X-Organization-Id": fixtureId("org") },
  );
  assert.equal(reply.status, 200);
  const viewing = await request(
    "POST",
    `/marketplace/inquiries/${inquiryId}/viewings`,
    {
      action: "request",
      scheduledAt: new Date(Date.now() + 86400000).toISOString(),
    },
    s.body.token,
  );
  assert.equal(viewing.status, 200);
  const updated = await request(
    "PUT",
    `/viewings/${viewing.body.data.id}`,
    { revision: 1, status: "confirmed" },
    owner.body.token,
    { "X-Organization-Id": fixtureId("org") },
  );
  assert.equal(updated.status, 200, JSON.stringify(updated.body));
  const inbox = await request(
    "GET",
    "/account/notifications",
    undefined,
    s.body.token,
  );
  assert.equal(inbox.body.notifications.length, 2);
  assert.ok(
    inbox.body.notifications.every((n: any) => n.inquiryId === inquiryId),
  );
});
test("email delivery stays disabled even when SMTP is configured", async () => {
  const keys = ["EMAIL_DELIVERY_ENABLED", "SMTP_HOST", "SMTP_PORT"];
  const previous = keys.map((k) => process.env[k]);
  const id = randomUUID();
  Object.assign(process.env, {
    EMAIL_DELIVERY_ENABLED: "false",
    SMTP_HOST: "127.0.0.1",
    SMTP_PORT: String(await port()),
  });
  try {
    await deliverMail({
      id,
      destination: "test-only@example.com",
      title: "Local verification test",
      body: "Local development only.",
    });
    const stored = JSON.parse(
      await readFile(path.join(root, ".local/mail", id + ".json"), "utf8"),
    );
    assert.equal(stored.subject, "Local verification test");
    assert.equal(stored.to, "test-only@example.com");
  } finally {
    keys.forEach((k, i) => {
      if (previous[i] === undefined) delete process.env[k];
      else process.env[k] = previous[i];
    });
  }
});

test("deployment runtime role can serve account APIs but cannot change schema or migration history", async () => {
  const admin = cluster.getPgClient("postgres", "127.0.0.1");
  await admin.connect();
  const migrationPassword = randomUUID();
  // The role name is fixed inside this disposable cluster, never in a user DB.
  await admin.query(
    `CREATE ROLE kwadra_migrate LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${migrationPassword}'`,
  );
  await admin.query("CREATE DATABASE kwadra_role_test OWNER kwadra_migrate");
  const migrationUrl = new URL(pool.options.connectionString!);
  migrationUrl.pathname = "/kwadra_role_test";
  migrationUrl.username = "kwadra_migrate";
  migrationUrl.password = migrationPassword;
  const runtimeUrl = new URL(pool.options.connectionString!);
  runtimeUrl.pathname = "/kwadra_role_test";
  const migration = createPool(migrationUrl.toString()),
    runtime = createPool(runtimeUrl.toString());
  let runtimeServer: Server | undefined;
  try {
    await migration.query("GRANT USAGE ON SCHEMA public TO kwadra_app");
    await migration.query(
      "ALTER DEFAULT PRIVILEGES FOR ROLE kwadra_migrate IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO kwadra_app",
    );
    await migrate(migration);
    await migration.query("REVOKE ALL ON schema_migrations FROM kwadra_app");
    await migration.query("GRANT SELECT ON schema_migrations TO kwadra_app");
    assert.equal(
      (await runtime.query("SELECT count(*)::int n FROM schema_migrations"))
        .rows[0].n,
      5,
    );
    await assert.rejects(
      runtime.query("CREATE TABLE public.forbidden(id integer)"),
      { code: "42501" },
    );
    await assert.rejects(runtime.query("DELETE FROM schema_migrations"), {
      code: "42501",
    });
    const id = randomUUID();
    await runtime.query(
      "INSERT INTO users(id,name,email,password_hash,email_verified_at,marketplace_account) VALUES($1,'Runtime test','runtime@example.com',$2,now(),true)",
      [id, passwordHash],
    );
    runtimeServer = createApp(runtime, { testing: true }).listen(
      0,
      "127.0.0.1",
    );
    await new Promise<void>((r) => runtimeServer!.once("listening", r));
    const origin = `http://127.0.0.1:${(runtimeServer.address() as net.AddressInfo).port}`;
    const signed = await fetch(origin + "/api/v1/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        email: "runtime@example.com",
        password: demoPassword,
        client: "native",
      }),
    });
    assert.equal(signed.status, 200, await signed.clone().text());
    const body = (await signed.json()) as any;
    const notices = await fetch(origin + "/api/v1/account/notifications", {
      headers: { Authorization: "Bearer " + body.token },
    });
    assert.equal(notices.status, 200);
  } finally {
    if (runtimeServer) {
      runtimeServer.closeAllConnections();
      await new Promise<void>((r) => runtimeServer!.close(() => r()));
    }
    await migration.end();
    await runtime.end();
    await admin.query("DROP DATABASE kwadra_role_test");
    await admin.query("DROP ROLE kwadra_migrate");
    await admin.end();
  }
});
