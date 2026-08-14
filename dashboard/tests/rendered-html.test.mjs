import assert from "node:assert/strict";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(new Request("http://localhost/", { headers: { accept: "text/html" } }), {
    ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) },
  }, { waitUntil() {}, passThroughOnException() {} });
}

test("renderiza o login protegido do LabMonitor", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /<title>Entrar • IFMS LabMonitor<\/title>/i);
  assert.match(html, /ACESSO INSTITUCIONAL/);
  assert.match(html, /name="password"/);
  assert.match(html, /nunca ficam armazenadas em texto legível/);
  assert.doesNotMatch(html, /codex-preview|SkeletonPreview/);
});
