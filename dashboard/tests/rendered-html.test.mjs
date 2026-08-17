import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
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

test("aceita senha temporária baseada em SIAPE com 7 caracteres", async () => {
  const page = await readFile(new URL("../github-pages/index.html", import.meta.url), "utf8");
  const edgeFunction = await readFile(new URL("../../supabase/functions/admin-users/index.ts", import.meta.url), "utf8");

  assert.match(page, /id="user-password"[^>]+minlength="7"/);
  assert.match(edgeFunction, /password\.length<7/);
});

test("separa inventário de atualizações e permite escolher computadores", async () => {
  const page = await readFile(new URL("../github-pages/index.html", import.meta.url), "utf8");
  const app = await readFile(new URL("../github-pages/app.js", import.meta.url), "utf8");

  assert.match(page, /id="update-device-rows"/);
  assert.match(page, /id="inventory-job-rows"/);
  assert.match(page, /id="update-job-rows"/);
  assert.match(page, />Aplicar atualização</);
  assert.match(app, /job\.jobs\?\.type === "inventory_refresh"/);
  assert.match(app, /job\.jobs\?\.type === "agent_update"/);
});

test("oferece remoção protegida de usuários e métricas de armazenamento", async () => {
  const page = await readFile(new URL("../github-pages/index.html", import.meta.url), "utf8");
  const app = await readFile(new URL("../github-pages/app.js", import.meta.url), "utf8");
  const edgeFunction = await readFile(new URL("../../supabase/functions/admin-users/index.ts", import.meta.url), "utf8");
  const migrations = await readFile(new URL("../../supabase/migrations/20260817183313_admin_storage_metrics.sql", import.meta.url), "utf8");

  assert.match(page, /data-view="storage"/);
  assert.match(app, /adminFunction\("metrics"\)/);
  assert.match(app, /window\.confirm/);
  assert.match(edgeFunction, /body\.action==="delete"/);
  assert.match(edgeFunction, /admins\.length<=1/);
  assert.match(edgeFunction, /releases\.slice\(2\)/);
  assert.match(edgeFunction, /retained=releases\.slice\(0,2\)/);
  assert.match(edgeFunction, /body:JSON\.stringify\(\{active:true\}\)/);
  assert.match(edgeFunction, /storage\/v1\/object\/agent-releases/);
  assert.match(edgeFunction, /prefixes:obsolete\.map/);
  assert.match(page, /mantém somente a versão atual e a anterior/);
  assert.match(migrations, /revoke all on function public\.get_admin_storage_metrics\(\) from public/);
  assert.match(migrations, /security invoker/);
  assert.match(migrations, /grant execute on function public\.get_admin_storage_metrics\(\) to service_role/);
});
