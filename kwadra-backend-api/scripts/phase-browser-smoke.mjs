// Local Chrome acceptance check; requires npm run dev and a compiled Flutter web build.
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { createHmac, randomUUID } from "node:crypto";

const base = process.env.KWADRA_TEST_URL ?? "http://127.0.0.1:3000";
const output = resolve(".local/phase-browser-smoke");
await mkdir(output, { recursive: true });
const profile = await mkdtemp(resolve(tmpdir(), "kwadra-phases-browser-"));
const browser = spawn(
  process.env.KWADRA_CHROME ??
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  [
    "--headless=new",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--enable-unsafe-swiftshader",
    "--remote-debugging-port=9227",
    `--user-data-dir=${profile}`,
    "about:blank",
  ],
  { windowsHide: true, stdio: "ignore" },
);
const delay = (ms) => new Promise((r) => setTimeout(r, ms));
let socket,
  id = 0;
const pending = new Map(),
  failures = [],
  requests = [];
function call(method, params = {}) {
  return new Promise((done, reject) => {
    const requestId = ++id,
      timer = setTimeout(() => {
        pending.delete(requestId);
        reject(Error("Timed out: " + method));
      }, 20000);
    pending.set(requestId, {
      done: (v) => {
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
async function evaluate(expression) {
  const r = await call("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (r.exceptionDetails) throw Error(r.exceptionDetails.text);
  return r.result.value;
}
async function waitFor(expression) {
  for (let n = 0; n < 100; n++) {
    if (await evaluate(expression)) return;
    await delay(250);
  }
  throw Error("Page condition not satisfied: " + expression);
}
async function screenshot(name) {
  const r = await call("Page.captureScreenshot", { format: "png" });
  await writeFile(
    resolve(output, name + ".png"),
    Buffer.from(r.data, "base64"),
  );
}
async function metrics(width, height = 950) {
  await call("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: width < 600,
  });
}
async function navigate(path) {
  await call("Page.navigate", { url: base + path });
  await delay(500);
}
async function tree() {
  return (await call("Accessibility.getFullAXTree")).nodes;
}
async function label(text) {
  for (let n = 0; n < 100; n++) {
    if ((await tree()).some((v) => v.name?.value?.includes(text))) return;
    await delay(250);
  }
  throw Error("Missing label: " + text);
}
async function clickLabel(text, role) {
  const nodes = (await tree()).filter(
    (n) => n.backendDOMNodeId && (!role || n.role?.value === role),
  );
  const node =
    nodes.find((n) => n.name?.value === text) ??
    nodes.find((n) => n.name?.value?.startsWith(text));
  if (!node) throw Error("Missing control: " + text);
  await call("DOM.scrollIntoViewIfNeeded", {
    backendNodeId: node.backendDOMNodeId,
  });
  const { model } = await call("DOM.getBoxModel", {
    backendNodeId: node.backendDOMNodeId,
  });
  const q = model.content,
    x = (q[0] + q[2] + q[4] + q[6]) / 4,
    y = (q[1] + q[3] + q[5] + q[7]) / 4;
  for (const type of ["mousePressed", "mouseReleased"])
    await call("Input.dispatchMouseEvent", {
      type,
      x,
      y,
      button: "left",
      clickCount: 1,
    });
  await delay(350);
}
async function fill(text, value) {
  await clickLabel(text, "textbox");
  await call("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "a",
    code: "KeyA",
    windowsVirtualKeyCode: 65,
    modifiers: 2,
  });
  await call("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "a",
    code: "KeyA",
    windowsVirtualKeyCode: 65,
    modifiers: 2,
  });
  await call("Input.insertText", { text: value });
}
function demoCode() {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const bits = [..."JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"]
    .map((c) => alphabet.indexOf(c).toString(2).padStart(5, "0"))
    .join("");
  const key = Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)));
  const h = createHmac("sha1", key).update(counter).digest(),
    o = h.at(-1) & 15;
  return String((h.readUInt32BE(o) & 0x7fffffff) % 1000000).padStart(6, "0");
}
try {
  let targets;
  for (let n = 0; n < 100; n++) {
    try {
      targets = await (await fetch("http://127.0.0.1:9227/json")).json();
      break;
    } catch {
      await delay(200);
    }
  }
  if (!targets) throw Error("Chrome did not start");
  socket = new WebSocket(
    targets.find((t) => t.type === "page").webSocketDebuggerUrl,
  );
  await new Promise((done, reject) => {
    socket.addEventListener("open", done, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  socket.addEventListener("message", (e) => {
    const m = JSON.parse(e.data);
    if (m.id) {
      const p = pending.get(m.id);
      if (p) {
        pending.delete(m.id);
        m.error ? p.reject(Error(m.error.message)) : p.done(m.result);
      }
    }
    if (m.method === "Runtime.exceptionThrown")
      failures.push(m.params.exceptionDetails);
    if (
      m.method === "Network.requestWillBeSent" &&
      m.params.request.url.includes("/api/v1/")
    )
      requests.push({
        method: m.params.request.method,
        path: new URL(m.params.request.url).pathname,
      });
  });
  await call("Page.enable");
  await call("Runtime.enable");
  await call("Network.enable");
  await metrics(1440, 1050);
  await navigate("/marketplace");
  await waitFor("document.querySelectorAll('.card').length>0");
  await waitFor(
    "[...document.images].filter(i=>i.getBoundingClientRect().top<innerHeight).every(i=>i.complete&&i.naturalWidth>0)",
  );
  await screenshot("marketplace-desktop");
  const listingPath = await evaluate(
    "document.querySelector('.card').getAttribute('href')",
  );
  if (!(await evaluate("document.querySelector('link[rel=canonical]')!==null")))
    throw Error("Canonical metadata missing");
  await metrics(390);
  await screenshot("marketplace-phone");
  if (await evaluate("document.documentElement.scrollWidth>innerWidth"))
    throw Error("Marketplace phone overflow");
  await navigate(listingPath);
  await waitFor("document.querySelector('#inquiry-form')!==null");
  await screenshot("listing-phone");
  await evaluate("document.querySelector('[data-save]').click()");
  if (
    !(await evaluate(
      "document.querySelector('[data-save]').getAttribute('aria-pressed')==='true'",
    ))
  )
    throw Error("Favorite failed");
  await evaluate(
    `document.querySelector('#name').value='Browser Seeker';document.querySelector('#email').value=${JSON.stringify("seeker-" + randomUUID() + "@example.com")};document.querySelector('#message').value='Synthetic browser inquiry about this rental.';document.querySelector('#inquiry-form').requestSubmit()`,
  );
  await waitFor("document.querySelector('#inquiry-form .status a')!==null");
  const track = await evaluate(
    "document.querySelector('#inquiry-form .status a').getAttribute('href')",
  );
  await navigate(track);
  await waitFor(
    "document.querySelector('#messages').textContent.includes('Synthetic browser inquiry')",
  );
  await evaluate(
    "document.querySelector('#reply-message').value='A second synthetic message from the seeker.';document.querySelector('#reply-form').requestSubmit()",
  );
  await waitFor(
    "document.querySelector('#messages').textContent.includes('second synthetic message')",
  );
  await screenshot("inquiry-tracking");
  await navigate("/marketplace/saved");
  await waitFor("document.querySelector('#saved-list .card')!==null");
  await screenshot("saved-rentals");
  await navigate("/");
  await waitFor(
    "document.querySelector('flutter-view')!==null && document.getElementById('loading')===null",
  );
  await evaluate(
    "document.querySelector('flt-semantics-placeholder')?.click()",
  );
  await label("Find your next home.");
  await clickLabel("Account");
  await clickLabel("Sign in", "button");
  await label("Welcome back");
  await fill("Email address", "isabel.reyes@example.com");
  await fill("Password", "KwadraDemo!2026");
  await clickLabel("Sign in", "button");
  await label("My tenancy");
  await clickLabel("My tenancy", "button");
  await label("Your home");
  await screenshot("tenant-home");
  await clickLabel("Charges");
  await label("Your charges");
  await screenshot("tenant-charges");
  await clickLabel("Repairs");
  await clickLabel("Add request", "button");
  await label("Send request");
  await fill("Request title", "Browser tenant repair");
  await fill(
    "Describe what needs attention",
    "Synthetic browser test repair request.",
  );
  await clickLabel("Send request", "button");
  await label("Browser tenant repair");
  await screenshot("tenant-repairs");
  await clickLabel("More");
  await clickLabel("Sign out", "button");
  await label("Find your next home.");
  await clickLabel("Account");
  await clickLabel("Sign in", "button");
  await label("Welcome back");
  await fill("Email address", "platform@example.com");
  await fill("Password", "KwadraDemo!2026");
  await clickLabel("Sign in", "button");
  await label("Authenticator code");
  await fill("Authenticator code", demoCode());
  await clickLabel("Sign in", "button");
  await label("Moderation console");
  await clickLabel("Moderation console", "button");
  await label("Publisher reviews");
  await screenshot("moderation-publishers");
  await clickLabel("Listings");
  await label("Listing reviews");
  await screenshot("moderation-listings");
  await clickLabel("Reports");
  await label("Reports & appeals");
  await screenshot("moderation-reports");
  const report = {
    publicSearch: true,
    seoMetadata: true,
    mobileNoOverflow: true,
    favorite: true,
    inquiryAndSeekerReply: true,
    tenantSignIn: true,
    tenantChargeView: true,
    tenantRepairPersisted: true,
    moderatorMfaSignIn: true,
    moderatorViews: true,
    paymentRequests: requests.filter((r) =>
      /\/payments|\/proofs|\/receipts/.test(r.path),
    ).length,
    runtimeFailures: failures,
  };
  await writeFile(
    resolve(output, "report.json"),
    JSON.stringify(report, null, 2),
  );
  console.log(JSON.stringify(report, null, 2));
  if (failures.length) process.exitCode = 1;
} catch (e) {
  if (socket?.readyState === WebSocket.OPEN) {
    await screenshot("failure").catch(() => {});
    await writeFile(
      resolve(output, "failure-accessibility.json"),
      JSON.stringify(await tree(), null, 2),
    );
  }
  console.error(e);
  process.exitCode = 1;
} finally {
  if (socket?.readyState === WebSocket.OPEN)
    await call("Browser.close").catch(() => {});
  socket?.close();
  browser.kill();
}
