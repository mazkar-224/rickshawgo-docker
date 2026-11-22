// Tests for the RickshawGo API, with Node's built-in test runner (no extra dependencies).
// Each test run starts the real server on a free port with a fake key.
const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const net = require("node:net");
const path = require("node:path");

let child;
let base;

function freePort() {
  return new Promise((resolve) => {
    const srv = net.createServer().listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

async function waitForServer(url, tries = 50) {
  for (let i = 0; i < tries; i++) {
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`server did not start: ${url}`);
}

before(async () => {
  const port = await freePort();
  base = `http://127.0.0.1:${port}`;
  child = spawn(process.execPath, [path.join(__dirname, "..", "server.js")], {
    env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", MAPS_KEY: "not-a-real-key-tests-only" },
    stdio: "ignore",
  });
  await waitForServer(`${base}/api/health`);
});

after(() => {
  if (child) child.kill("SIGTERM");
});

test("GET /api/health reports ok and the version", async () => {
  const res = await fetch(`${base}/api/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.status, "ok");
  assert.equal(body.version, "2.2");
  assert.ok(body.instance, "instance (hostname) is reported");
});

test("GET /api/rickshaws/free lists only free rickshaws", async () => {
  const body = await (await fetch(`${base}/api/rickshaws/free`)).json();
  assert.ok(body.rickshaws.length > 0);
  assert.ok(body.rickshaws.every((r) => r.status === "free"));
});

test("GET /api/rickshaws/count matches the list", async () => {
  const all = (await (await fetch(`${base}/api/rickshaws`)).json()).rickshaws;
  const count = await (await fetch(`${base}/api/rickshaws/count`)).json();
  assert.equal(count.total, all.length);
  assert.equal(count.free, all.filter((r) => r.status === "free").length);
});

test("unknown paths answer 404 with JSON, and Express is not advertised", async () => {
  const res = await fetch(`${base}/nope`);
  assert.equal(res.status, 404);
  assert.equal(res.headers.get("x-powered-by"), null);
  assert.deepEqual(await res.json(), { error: "not found" });
});

test("the server refuses to start without MAPS_KEY", async () => {
  const env = { ...process.env, PORT: "0" };
  delete env.MAPS_KEY;
  const code = await new Promise((resolve) => {
    const p = spawn(process.execPath, [path.join(__dirname, "..", "server.js")], { env, stdio: "ignore" });
    p.on("exit", resolve);
  });
  assert.equal(code, 1);
});
