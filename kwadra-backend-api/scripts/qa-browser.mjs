import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
const delay = (ms) => new Promise((r) => setTimeout(r, ms));
export async function openBrowser(output, port = 9228) {
  await mkdir(output, { recursive: true });
  const profile = await mkdtemp(
    resolve(tmpdir(), "kwadra-mobile-marketplace-"),
  );
  const process = spawn(
    globalThis.process.env.KWADRA_CHROME ??
      "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    [
      "--headless=new",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      "--enable-unsafe-swiftshader",
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profile}`,
      "about:blank",
    ],
    { windowsHide: true, stdio: "ignore" },
  );
  let targets;
  for (let n = 0; n < 100; n++) {
    try {
      targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
      break;
    } catch {
      await delay(200);
    }
  }
  if (!targets) {
    process.kill();
    throw Error("Chrome did not start.");
  }
  const socket = new WebSocket(
    targets.find((t) => t.type === "page").webSocketDebuggerUrl,
  );
  await new Promise((done, reject) => {
    socket.addEventListener("open", done, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  let seq = 0;
  const pending = new Map(),
    failures = [],
    requests = [];
  socket.addEventListener("message", (event) => {
    const m = JSON.parse(event.data);
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
  function call(method, params = {}) {
    return new Promise((done, reject) => {
      const id = ++seq,
        timer = setTimeout(() => {
          pending.delete(id);
          reject(Error("Timeout: " + method));
        }, 20000);
      pending.set(id, {
        done: (r) => {
          clearTimeout(timer);
          done(r);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      socket.send(JSON.stringify({ id, method, params }));
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
  async function tree() {
    return (await call("Accessibility.getFullAXTree")).nodes;
  }
  async function wait(text) {
    for (let n = 0; n < 100; n++) {
      if ((await tree()).some((v) => v.name?.value?.includes(text))) return;
      await delay(250);
    }
    throw Error("Missing label: " + text);
  }
  async function click(text, role) {
    const nodes = (await tree()).filter(
        (n) => n.backendDOMNodeId && (!role || n.role?.value === role),
      ),
      node =
        nodes.find((n) => n.name?.value === text) ??
        nodes.find((n) => n.name?.value?.startsWith(text)) ??
        nodes.find((n) => n.name?.value?.includes(text));
    if (!node) throw Error("Missing control: " + text);
    await call("DOM.scrollIntoViewIfNeeded", {
      backendNodeId: node.backendDOMNodeId,
    });
    const { model } = await call("DOM.getBoxModel", {
        backendNodeId: node.backendDOMNodeId,
      }),
      q = model.content,
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
    await delay(300);
  }
  async function fill(text, value) {
    await click(text, "textbox");
    for (const type of ["keyDown", "keyUp"])
      await call("Input.dispatchKeyEvent", {
        type,
        key: "a",
        code: "KeyA",
        windowsVirtualKeyCode: 65,
        modifiers: 2,
      });
    await call("Input.insertText", { text: value });
  }
  async function screenshot(name) {
    const r = await call("Page.captureScreenshot", { format: "png" });
    await writeFile(
      resolve(output, name + ".png"),
      Buffer.from(r.data, "base64"),
    );
  }
  async function open(url) {
    await call("Page.navigate", { url });
    for (let n = 0; n < 120; n++) {
      if (
        await evaluate(
          "document.querySelector('flutter-view')!==null&&document.getElementById('loading')===null",
        )
      )
        break;
      await delay(250);
    }
    await evaluate(
      "document.querySelector('flt-semantics-placeholder')?.click()",
    );
  }
  await call("Page.enable");
  await call("Runtime.enable");
  await call("Network.enable");
  return {
    call,
    evaluate,
    tree,
    wait,
    click,
    fill,
    screenshot,
    open,
    failures,
    requests,
    delay,
    metrics: async (width, height = 1000) =>
      call("Emulation.setDeviceMetricsOverride", {
        width,
        height,
        deviceScaleFactor: 1,
        mobile: width < 600,
      }),
    failure: async () => {
      await screenshot("failure");
      await writeFile(
        resolve(output, "failure-accessibility.json"),
        JSON.stringify(await tree(), null, 2),
      );
    },
    close: async () => {
      if (socket.readyState === WebSocket.OPEN)
        socket.send(JSON.stringify({ id: ++seq, method: "Browser.close" }));
      await delay(400);
      socket.close();
      process.kill();
    },
  };
}
