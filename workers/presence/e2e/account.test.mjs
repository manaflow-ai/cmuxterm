import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";
import { Miniflare } from "miniflare";

const directory = await mkdtemp(join(tmpdir(), "cmux-account-e2e-"));
const { outputFiles } = await build({
  entryPoints: [new URL("./account.worker.ts", import.meta.url).pathname],
  bundle: true, write: false, format: "esm", target: "es2022", external: ["cloudflare:workers"],
});
let runtime;
let outboundCalls = 0;
const start = async () => {
  runtime = new Miniflare({
    name: "account-storage-sandbox", modules: true, script: outputFiles[0].text,
    compatibilityDate: "2026-05-01", host: "127.0.0.1", port: 0,
    durableObjects: { ACCOUNT: { className: "SandboxAccount", useSQLite: true } },
    durableObjectsPersist: directory,
    outboundService: () => { outboundCalls++; throw new Error("External network is blocked in this sandbox"); },
  });
  await runtime.ready;
};
const request = async (path, body) => {
  const response = await runtime.dispatchFetch(`http://sandbox${path}`, body === undefined ? {} : {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
  });
  const text = await response.text();
  assert.equal(response.status, 200, text);
  return JSON.parse(text);
};
try {
  await start();
  const first = await request("/inspect");
  assert.deepEqual(first.schema, [{ version: 1, name: "account_state_tables" }]);
  assert.deepEqual(first.rows, []);
  assert.equal(first.alarm, null, "Empty SQL state must not start a permanent daily alarm");
  const expiry = Date.now() + 120_000;
  await request("/seed", { id: "keep", expiresAt: expiry });
  await request("/set-alarm", { at: expiry });
  await runtime.dispose();
  await start();
  const restarted = await request("/inspect");
  assert.equal(restarted.alarm, expiry, "Reactivation must preserve an existing earlier alarm");
  assert.deepEqual(restarted.rows, [{ challenge_id: "keep", expires_at: expiry }]);
  assert.deepEqual((await request("/inspect?account=b")).rows, [], "Accounts must have separate SQLite databases");
  await request("/seed", { id: "expired", expiresAt: Date.now() - 1 });
  await request("/alarm");
  const cleaned = await request("/inspect");
  assert.deepEqual(cleaned.rows, [{ challenge_id: "keep", expires_at: expiry }]);
  assert.equal(cleaned.alarm, expiry, "Idle object must rearm cleanup for retained records");
  assert.equal(outboundCalls, 0);
  console.log(JSON.stringify({ result: "pass", checks: ["fresh schema", "persisted restart", "migration idempotence", "account isolation", "alarm preservation", "idle cleanup", "alarm rearm", "external network blocked"] }));
} finally {
  await runtime?.dispose();
  await rm(directory, { recursive: true, force: true });
}
