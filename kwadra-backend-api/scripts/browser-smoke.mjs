// Real Flutter web -> API -> PostgreSQL smoke check. Run with npm run dev
// already serving a release Flutter build, then: node scripts/browser-smoke.mjs
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { randomUUID } from "node:crypto";
import pg from "pg";

process.loadEnvFile(".env");
const base = process.env.KWADRA_TEST_URL ?? "http://127.0.0.1:3000";
const output = resolve(".local/browser-smoke");
await mkdir(output, { recursive: true });
const email = `browser-${randomUUID()}@example.com`,
  password = "BrowserTest!2026";
const created = await fetch(base + "/api/v1/auth/register", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    name: "Browser Tester",
    email,
    password,
    organization: "Browser smoke test",
  }),
});
if (created.status !== 201)
  throw new Error("Could not create isolated browser test account.");
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const verification = (
  await pool.query(
    "SELECT body FROM delivery_logs WHERE destination=$1 AND title='Verify your Kwadra email' ORDER BY created_at DESC LIMIT 1",
    [email],
  )
).rows[0];
const token = verification?.body.match(/[a-f0-9]{64}/)?.[0];
if (!token) throw new Error("No development verification code was queued.");
const verified = await fetch(base + "/api/v1/identity/verify", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ token }),
});
if (!verified.ok) throw new Error("Browser test email verification failed.");
const org = (
  await pool.query(
    "SELECT m.organization_id FROM memberships m JOIN users u ON u.id=m.user_id WHERE u.email=$1",
    [email],
  )
).rows[0].organization_id;
const profile = await mkdtemp(resolve(tmpdir(), "kwadra-api-browser-"));
const browser = spawn(
  process.env.KWADRA_CHROME ??
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  [
    "--headless=new",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--enable-unsafe-swiftshader",
    "--remote-debugging-port=9226",
    `--user-data-dir=${profile}`,
    "about:blank",
  ],
  { windowsHide: true, stdio: "ignore" },
);
const delay = (ms) => new Promise((done) => setTimeout(done, ms));
let socket,
  id = 0;
const pending = new Map(),
  failures = [],
  apiRequests = [];
try {
  let targets;
  for (let i = 0; i < 100; i++) {
    try {
      targets = await (await fetch("http://127.0.0.1:9226/json")).json();
      break;
    } catch {
      await delay(200);
    }
  }
  if (!targets) throw new Error("Chrome did not start.");
  socket = new WebSocket(
    targets.find((t) => t.type === "page").webSocketDebuggerUrl,
  );
  await new Promise((done, reject) => {
    socket.addEventListener("open", done, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const task = pending.get(message.id);
      if (task) {
        pending.delete(message.id);
        message.error
          ? task.reject(new Error(JSON.stringify(message.error)))
          : task.resolve(message.result);
      }
    }
    if (message.method === "Runtime.exceptionThrown")
      failures.push(message.params.exceptionDetails);
    if (message.method === "Network.requestWillBeSent") {
      const r = message.params.request;
      if (r.url.includes("/api/v1/"))
        apiRequests.push({ url: r.url, method: r.method });
    }
  });
  function call(method, params = {}) {
    return new Promise((done, reject) => {
      const requestId = ++id,
        timer = setTimeout(() => {
          pending.delete(requestId);
          reject(new Error("Timed out: " + method));
        }, 20000);
      pending.set(requestId, {
        resolve: (v) => {
          clearTimeout(timer);
          done(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      socket.send(JSON.stringify({ id: requestId, method, params }));
    });
  }
  async function click(x, y) {
    await call("Input.dispatchMouseEvent", {
      type: "mousePressed",
      x,
      y,
      button: "left",
      clickCount: 1,
    });
    await call("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x,
      y,
      button: "left",
      clickCount: 1,
    });
    await delay(350);
  }
  async function tree() {
    return (await call("Accessibility.getFullAXTree")).nodes;
  }
  async function waitLabel(label) {
    for (let i = 0; i < 80; i++) {
      if ((await tree()).some((n) => n.name?.value?.includes(label))) return;
      await delay(250);
    }
    throw new Error("Missing label: " + label);
  }
  async function clickLabel(label, role) {
    const nodes = await tree(),
      candidates = nodes.filter(
        (n) => n.backendDOMNodeId && (!role || n.role?.value === role),
      );
    const node =
      candidates.find((n) => n.name?.value === label) ??
      candidates.find((n) => n.name?.value?.startsWith(label));
    if (!node) throw new Error("Missing control: " + label);
    await call("DOM.scrollIntoViewIfNeeded", {
      backendNodeId: node.backendDOMNodeId,
    });
    const { model } = await call("DOM.getBoxModel", {
        backendNodeId: node.backendDOMNodeId,
      }),
      q = model.content;
    await click(
      (q[0] + q[2] + q[4] + q[6]) / 4,
      (q[1] + q[3] + q[5] + q[7]) / 4,
    );
  }
  async function fill(label, value) {
    await clickLabel(label, "textbox");
    await call("Input.insertText", { text: value });
    await delay(150);
  }
  async function screenshot(name) {
    const shot = await call("Page.captureScreenshot", { format: "png" });
    await writeFile(
      resolve(output, name + ".png"),
      Buffer.from(shot.data, "base64"),
    );
  }
  await call("Runtime.enable");
  await call("Network.enable");
  await call("Page.enable");
  await call("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 1100,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await call("Page.navigate", { url: base });
  for (let i = 0; i < 120; i++) {
    const r = await call("Runtime.evaluate", {
      expression:
        "document.querySelector('flutter-view') !== null && document.getElementById('loading') === null",
      returnByValue: true,
    });
    if (r.result.value) break;
    await delay(250);
  }
  await call("Runtime.evaluate", {
    expression: "document.querySelector('flt-semantics-placeholder')?.click()",
  });
  await waitLabel("Find your next home.");
  await clickLabel("Account");
  await clickLabel("Sign in", "button");
  await waitLabel("Welcome back");
  await screenshot("login");
  await fill("Email address", email);
  await fill("Password", password);
  await clickLabel("Sign in", "button");
  await waitLabel("Manage rentals");
  await clickLabel("Manage rentals", "button");
  await waitLabel("Hi, Browser");
  await clickLabel("Properties");
  await clickLabel("Add property", "button");
  await waitLabel("Property name");
  await fill("Property name", "Browser verified property");
  await fill("Location / address", "Cebu City");
  await clickLabel("Add property", "button");
  await waitLabel("Browser verified property");
  await screenshot("saved-property");
  const saved = (
    await pool.query("SELECT * FROM properties WHERE organization_id=$1", [org])
  ).rows;
  if (saved.length !== 1 || saved[0].name !== "Browser verified property")
    throw new Error("Flutter creation did not persist in PostgreSQL.");
  await clickLabel("Browser verified property");
  await clickLabel("Add unit", "button");
  await fill("Unit code", "T-01");
  await fill("Monthly rent (PHP)", "1250.50");
  await clickLabel("Add unit", "button");
  await waitLabel("T-01");
  await delay(400);
  await clickLabel("Tenants");
  await clickLabel("Add tenant", "button");
  await fill("Full name", "Casey Sample");
  await fill("Email address", "casey.sample@example.com");
  await fill("Phone number", "09170000000");
  await clickLabel("Add tenant", "button");
  await waitLabel("Casey Sample");
  await delay(400);
  await clickLabel("More");
  await clickLabel("Leases");
  await clickLabel("Create lease", "button");
  await clickLabel("Add tenant");
  await clickLabel("Casey Sample");
  await clickLabel("Create lease", "button");
  await delay(900);
  if (
    (
      await pool.query(
        "SELECT count(*)::int AS n FROM leases WHERE organization_id=$1",
        [org],
      )
    ).rows[0].n !== 1
  )
    throw new Error("Flutter lease did not persist.");
  await clickLabel("More");
  await clickLabel("Rent invoices");
  await clickLabel("Generate rent", "button");
  await clickLabel("Generate invoices", "button");
  await delay(700);
  const charge = (
    await pool.query("SELECT amount FROM invoices WHERE organization_id=$1", [
      org,
    ])
  ).rows;
  if (charge.length !== 1 || charge[0].amount !== "1250.50")
    throw new Error(
      "Flutter invoice generation did not persist the exact amount.",
    );
  await clickLabel("More");
  await clickLabel("Repairs");
  await clickLabel("Add request", "button");
  await fill("Request title", "Browser verified repair");
  await fill(
    "Describe what needs attention",
    "Synthetic repair request from the browser smoke check.",
  );
  await clickLabel("Create request", "button");
  await waitLabel("Browser verified repair");
  await delay(400);
  if (
    (
      await pool.query(
        "SELECT count(*)::int AS n FROM maintenance_tickets WHERE organization_id=$1",
        [org],
      )
    ).rows[0].n !== 1
  )
    throw new Error("Flutter repair did not persist.");
  // A full page reload must restore the HttpOnly session and the server data.
  await call("Page.reload");
  await delay(1800);
  await call("Runtime.evaluate", {
    expression: "document.querySelector('flt-semantics-placeholder')?.click()",
  });
  await waitLabel("Find your next home.");
  await clickLabel("Account");
  await clickLabel("Manage rentals", "button");
  await waitLabel("Hi, Browser");
  await clickLabel("Properties");
  await waitLabel("Browser verified property");
  await clickLabel("More");
  await clickLabel("Payment preview");
  const requestCount = apiRequests.length;
  await clickLabel("Continue sample", "button");
  await clickLabel("Review sample", "button");
  await clickLabel("Finish preview", "button");
  await waitLabel("Preview complete");
  await screenshot("payment-preview");
  if (apiRequests.length !== requestCount)
    throw new Error("Payment preview sent a request.");
  if (
    (await pool.query("SELECT count(*)::int AS n FROM payments")).rows[0].n !==
    0
  )
    throw new Error("Unexpected payment rows.");
  await clickLabel("Home");
  await call("Emulation.setDeviceMetricsOverride", {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  });
  await delay(600);
  await screenshot("mobile-home");
  await clickLabel("More");
  await clickLabel("Settings");
  await clickLabel("Sign out", "button");
  await waitLabel("Find your next home.");
  const report = {
    signedIn: true,
    flutterPropertyPersisted: true,
    flutterUnitTenantLeaseInvoiceRepairPersisted: true,
    cookieSessionRestored: true,
    paymentPreviewRequests: 0,
    paymentRows: 0,
    signedOut: true,
    runtimeFailures: failures,
  };
  await writeFile(
    resolve(output, "report.json"),
    JSON.stringify(report, null, 2),
  );
  console.log(JSON.stringify(report, null, 2));
  if (failures.length) process.exitCode = 1;
  socket.send(JSON.stringify({ id: ++id, method: "Browser.close" }));
  await Promise.race([
    new Promise((done) => browser.once("exit", done)),
    delay(1000),
  ]);
} catch (error) {
  if (socket?.readyState === 1) {
    const requestId = ++id;
    socket.send(
      JSON.stringify({ id: requestId, method: "Accessibility.getFullAXTree" }),
    );
    await new Promise((done) => {
      const listener = async (event) => {
        const message = JSON.parse(event.data);
        if (message.id === requestId) {
          await writeFile(
            resolve(output, "failure-accessibility.json"),
            JSON.stringify(message.result, null, 2),
          );
          socket.removeEventListener("message", listener);
          done();
        }
      };
      socket.addEventListener("message", listener);
      setTimeout(done, 2000);
    });
  }
  console.error(error);
  process.exitCode = 1;
} finally {
  socket?.close();
  browser.kill();
  await pool.end();
}
