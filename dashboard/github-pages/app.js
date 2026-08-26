import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const config = window.LABMONITOR_CONFIG || {};
const configured = /^https:\/\/.+\.supabase\.co$/.test(config.supabaseUrl || "") && !String(config.publishableKey || "").includes("SUBSTITUA");
const supabase = configured ? createClient(config.supabaseUrl, config.publishableKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } }) : null;
const $ = (id) => document.getElementById(id);
const state = { profile: null, devices: [], events: [], software: [], releases: [], jobs: [], requests: [], storageMetrics: null, selected: new Set(), selectedRequests: new Set(), retentionDays: 90, remoteUpdatesEnabled: true };
const eventLabels = { ProhibitedApplicationDetected: "Aplicativo proibido detectado", ProhibitedApplicationStopped: "Aplicativo proibido encerrado", SuspiciousApplicationDetected: "Aplicativo suspeito detectado", SuspiciousApplicationStopped: "Aplicativo suspeito encerrado", WallpaperChanged: "Papel de parede alterado" };
const esc = (value) => String(value ?? "—").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const eventName = (value) => eventLabels[value] || value;
const isOnline = (device) => Date.now() - new Date(device.last_seen_at).getTime() < 1500000;
const ago = (iso) => { const minutes = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000)); return minutes < 1 ? "agora" : minutes < 60 ? `há ${minutes} min` : minutes < 1440 ? `há ${Math.round(minutes / 60)} h` : `há ${Math.round(minutes / 1440)} d`; };
const formatBytes = (bytes) => { const value = Number(bytes || 0); if (value < 1024) return `${value} bytes`; if (value < 1048576) return `${(value / 1024).toFixed(1)} KB`; if (value < 1073741824) return `${(value / 1048576).toFixed(1)} MB`; return `${(value / 1073741824).toFixed(2)} GB`; };

function message(text, error = false) { const el = $("app-message"); el.textContent = text; el.className = `message${error ? " error" : ""}`; el.hidden = !text; }
function loginMessage(text) { const el = $("login-message"); el.textContent = text; el.hidden = !text; }
function emptyRow(columns, text) { return `<tr><td colspan="${columns}"><div class="empty">${esc(text)}</div></td></tr>`; }

async function start() {
  if (!configured) { loginMessage("A conexão com o Supabase ainda está sendo configurada."); return; }
  const { data: { session } } = await supabase.auth.getSession();
  if (session) await enterApp(session.user);
  supabase.auth.onAuthStateChange((_event, nextSession) => { if (!nextSession) showLogin(); });
}

async function enterApp(user) {
  const { data: profile, error } = await supabase.from("profiles").select("id,email,full_name,role,active").eq("id", user.id).single();
  if (error || !profile?.active) { await supabase.auth.signOut(); loginMessage("Seu acesso ainda não foi autorizado pelo administrador."); return; }
  state.profile = profile;
  $("login-view").hidden = true; $("app-view").hidden = false;
  $("profile-name").textContent = profile.full_name; $("profile-role").textContent = profile.role === "admin" ? "Administrador" : "Monitor";
  $("avatar").textContent = profile.full_name.split(/\s+/).slice(0, 2).map((x) => x[0]).join("").toUpperCase();
  document.querySelectorAll("[data-admin]").forEach((el) => { el.hidden = profile.role !== "admin"; });
  await loadData();
}

function showLogin() { state.profile = null; $("app-view").hidden = true; $("login-view").hidden = false; }

async function loadData() {
  message("");
  const storageMetricsRequest = state.profile.role === "admin" ? adminFunction("metrics").then((result) => ({ data: result.metrics, error: null })).catch((error) => ({ data: null, error })) : Promise.resolve({ data: null, error: null });
  const results = await Promise.all([
    supabase.from("devices").select("id,hostname,agent_version,status,last_seen_at,inventory_collected_at,os_type,os_version,primary_mac,local_ip_addresses,public_ip").order("hostname"),
    supabase.from("device_events").select("event_id,occurred_at,event_type,user_name,payload,devices(hostname)").order("occurred_at", { ascending: false }).limit(100),
    supabase.from("software_inventory").select("device_id,inventory_key,name,version,publisher,scope,architecture,devices(hostname)").order("name").limit(5000),
    supabase.from("agent_releases").select("id,version,active,created_at").order("created_at", { ascending: false }),
    supabase.from("device_jobs").select("job_id,status,leased_at,completed_at,result,devices(hostname),jobs(type,created_at)").order("leased_at", { ascending: false, nullsFirst: false }).limit(100),
    supabase.from("system_settings").select("event_retention_days,remote_updates_enabled").eq("id", true).maybeSingle(),
    supabase.from("device_enrollment_requests").select("id,hostname,mac_addresses,local_ip_addresses,request_ip,os_type,os_version,agent_version,status,last_requested_at,matched_device_id,match_score,match_reasons").order("last_requested_at", { ascending: false }).limit(200),
    storageMetricsRequest
  ]);
  const failed = results.slice(0, 7).find((item) => item.error);
  if (failed) { message("Não foi possível carregar os dados. Verifique a configuração do Supabase.", true); return; }
  [state.devices, state.events, state.software, state.releases, state.jobs] = results.slice(0, 5).map((item) => item.data || []);
  state.retentionDays = results[5].data?.event_retention_days || 90;
  state.remoteUpdatesEnabled = results[5].data?.remote_updates_enabled === true;
  state.requests = results[6].data || [];
  state.storageMetrics = results[7].data || null;
  render();
}

function render() {
  const counts = new Map(); state.software.forEach((s) => counts.set(s.device_id, (counts.get(s.device_id) || 0) + 1));
  $("metric-devices").textContent = state.devices.length; $("metric-online").textContent = state.devices.filter(isOnline).length;
  $("metric-alerts").textContent = state.events.filter((e) => ["ProhibitedApplicationDetected", "SuspiciousApplicationDetected", "WallpaperChanged"].includes(e.event_type) && Date.now() - new Date(e.occurred_at) < 86400000).length;
  $("metric-software").textContent = state.software.length;
  $("overview-devices").innerHTML = state.devices.slice(0, 10).map((d) => `<tr><td><b>${esc(d.hostname)}</b></td><td>${esc(d.os_type || "Windows")} ${esc(d.os_version || "")}</td><td><span class="status ${isOnline(d) ? "online" : ""}"><i></i>${isOnline(d) ? "Online" : "Offline"}</span></td><td>v${esc(d.agent_version)}</td></tr>`).join("") || emptyRow(4, "Nenhum computador cadastrado.");
  $("recent-events").innerHTML = state.events.slice(0, 6).map((e) => `<div class="event-item"><b>${esc(eventName(e.event_type))}</b><small>${esc(e.devices?.hostname)} • ${esc(e.user_name || "SYSTEM")} • ${ago(e.occurred_at)}</small></div>`).join("") || '<div class="empty">Nenhum evento recebido.</div>';
  $("device-rows").innerHTML = state.devices.map((d) => `<tr><td><input class="device-check" type="checkbox" aria-label="Selecionar ${esc(d.hostname)}" data-device="${esc(d.id)}" ${state.selected.has(d.id) ? "checked" : ""} ${state.profile.role !== "admin" ? "disabled" : ""}></td><td><b>${esc(d.hostname)}</b></td><td>${esc(d.os_type || "Windows")} ${esc(d.os_version || "")}</td><td>${esc(d.primary_mac)}</td><td>${esc((d.local_ip_addresses || []).join(", ") || d.public_ip)}</td><td><span class="status ${isOnline(d) ? "online" : ""}"><i></i>${isOnline(d) ? "Online" : "Offline"}</span></td><td>v${esc(d.agent_version)}</td><td>${counts.get(d.id) || 0}</td><td>${ago(d.last_seen_at)}</td></tr>`).join("") || emptyRow(9, "Nenhum computador cadastrado.");
  $("event-count").textContent = `${state.events.length} eventos`; $("event-rows").innerHTML = state.events.map((e) => `<tr><td>${new Date(e.occurred_at).toLocaleString("pt-BR")}</td><td><span class="badge ${["ProhibitedApplicationDetected", "SuspiciousApplicationDetected", "WallpaperChanged"].includes(e.event_type) ? "alert" : ""}">${esc(eventName(e.event_type))}</span></td><td>${esc(e.devices?.hostname)}</td><td>${esc(e.user_name || "SYSTEM")}</td><td>${esc(e.event_type === "WallpaperChanged" ? "Alteração detectada (imagem não armazenada)" : e.payload?.displayName || e.payload?.processName || "—")}</td></tr>`).join("") || emptyRow(5, "Nenhuma ocorrência recebida.");
  $("software-device").innerHTML = '<option value="">Todos os computadores</option>' + state.devices.map((d) => `<option value="${esc(d.id)}">${esc(d.hostname)}</option>`).join("");
  $("inventory-count").textContent = `${state.software.length} instalações`; renderSoftware();
  $("release-select").innerHTML = '<option value="">Selecione uma versão</option>' + state.releases.filter((r) => r.active).map((r) => `<option value="${esc(r.id)}">Versão ${esc(r.version)}</option>`).join("");
  $("remote-update-status").textContent = state.remoteUpdatesEnabled ? "Atualizações habilitadas" : "Atualizações desabilitadas";
  $("remote-update-status").className = `badge ${state.remoteUpdatesEnabled ? "active" : "inactive"}`;
  $("toggle-remote-updates").textContent = state.remoteUpdatesEnabled ? "Desabilitar atualizações" : "Habilitar atualizações";
  $("update-device-rows").innerHTML = state.devices.map((d) => `<tr><td><input class="device-check" type="checkbox" aria-label="Selecionar ${esc(d.hostname)} para atualização" data-device="${esc(d.id)}" ${state.selected.has(d.id) ? "checked" : ""}></td><td><b>${esc(d.hostname)}</b></td><td>v${esc(d.agent_version)}</td><td><span class="status ${isOnline(d) ? "online" : ""}"><i></i>${isOnline(d) ? "Online" : "Offline"}</span></td><td>${ago(d.last_seen_at)}</td></tr>`).join("") || emptyRow(5, "Nenhum computador cadastrado.");
  renderJobHistory();
  renderStorageMetrics();
  $("retention-days").value = String(state.retentionDays);
  renderRequests();
  bindDeviceChecks();
}

function renderJobHistory() {
  const ordered = [...state.jobs].sort((a, b) => new Date(b.jobs?.created_at || 0) - new Date(a.jobs?.created_at || 0));
  const inventoryJobs = ordered.filter((job) => job.jobs?.type === "inventory_refresh");
  const updateJobs = ordered.filter((job) => job.jobs?.type === "agent_update");
  const lastInventory = inventoryJobs[0];
  $("last-inventory-request").textContent = lastInventory ? ago(lastInventory.jobs.created_at) : "Nunca";
  $("last-inventory-detail").textContent = lastInventory ? `${lastInventory.devices?.hostname || "Computador"} • ${lastInventory.status}` : "Nenhuma solicitação registrada";
  $("inventory-job-count").textContent = `${inventoryJobs.length} ${inventoryJobs.length === 1 ? "solicitação" : "solicitações"}`;
  $("inventory-job-rows").innerHTML = inventoryJobs.map((j) => `<tr><td>${esc(j.devices?.hostname)}</td><td>${ago(j.jobs?.created_at)}</td><td><span class="badge">${esc(j.status)}</span></td><td>${j.completed_at ? ago(j.completed_at) : "—"}</td><td>${esc(j.result?.message || "—")}</td></tr>`).join("") || emptyRow(5, "Nenhuma solicitação de inventário.");
  $("update-job-count").textContent = `${updateJobs.length} ${updateJobs.length === 1 ? "atualização" : "atualizações"}`;
  $("update-job-rows").innerHTML = updateJobs.map((j) => `<tr><td>${esc(j.devices?.hostname)}</td><td><span class="badge">${esc(j.status)}</span></td><td>${j.leased_at ? new Date(j.leased_at).toLocaleString("pt-BR") : "Aguardando"}</td><td>${j.completed_at ? new Date(j.completed_at).toLocaleString("pt-BR") : "—"}</td><td>${esc(j.result?.message || "—")}</td></tr>`).join("") || emptyRow(5, "Nenhuma atualização enviada.");
}

function renderStorageMetrics() {
  const metrics = state.storageMetrics;
  if (!metrics) { $("database-usage").textContent = $("object-storage-usage").textContent = "Indisponível"; $("database-usage-detail").textContent = $("object-storage-detail").textContent = "Tente recarregar a página"; return; }
  const databasePercent = Math.min(100, Number(metrics.databaseBytes || 0) / Number(metrics.databaseLimitBytes || 1) * 100);
  const objectPercent = Math.min(100, Number(metrics.objectStorageBytes || 0) / Number(metrics.objectStorageLimitBytes || 1) * 100);
  $("database-usage").textContent = `${formatBytes(metrics.databaseBytes)} de ${formatBytes(metrics.databaseLimitBytes)}`;
  $("database-usage-detail").textContent = `${databasePercent.toFixed(1)}% da cota do plano gratuito`;
  $("object-storage-usage").textContent = `${formatBytes(metrics.objectStorageBytes)} de ${formatBytes(metrics.objectStorageLimitBytes)}`;
  $("object-storage-detail").textContent = `${objectPercent.toFixed(1)}% • ${Number(metrics.objectCount || 0)} arquivos`;
  [["database-progress", databasePercent], ["object-storage-progress", objectPercent]].forEach(([id, percent]) => { const bar = $(id); bar.style.width = `${percent}%`; bar.className = percent >= 90 ? "danger" : percent >= 70 ? "warning" : ""; });
  $("storage-measured-at").textContent = metrics.measuredAt ? `medido ${ago(metrics.measuredAt)}` : "medição atual";
}

function renderRequests() {
  const pending = state.requests.filter((request) => request.status === "pending").length;
  $("pending-request-count").textContent = String(pending);
  $("pending-request-count").hidden = !pending;
  const labels = { pending: "Aguardando", approved: "Autorizado", rejected: "Recusado", claimed: "Cadastrado" };
  state.selectedRequests = new Set([...state.selectedRequests].filter((id) => state.requests.some((request) => request.id === id && request.status !== "claimed")));
  $("request-rows").innerHTML = state.requests.map((request) => { const matched = state.devices.find((device) => device.id === request.matched_device_id); const recognition = matched ? `<b>Mesmo PC: ${esc(matched.hostname)}</b><small>${esc((request.match_reasons || []).join(", "))}</small>` : "Novo computador"; return `<tr><td><input class="request-check" type="checkbox" aria-label="Selecionar ${esc(request.hostname)}" data-request="${esc(request.id)}" ${request.status === "claimed" ? "disabled" : ""} ${state.selectedRequests.has(request.id) ? "checked" : ""}></td><td><b>${esc(request.hostname)}</b><small>Agente v${esc(request.agent_version)}</small></td><td>${esc((request.mac_addresses || []).join(", "))}</td><td>${esc((request.local_ip_addresses || []).join(", "))}</td><td>${esc(request.request_ip)}</td><td>${esc(request.os_type)} ${esc(request.os_version)}</td><td>${recognition}</td><td>${ago(request.last_requested_at)}</td><td><span class="badge ${request.status === "pending" ? "alert" : request.status === "claimed" || request.status === "approved" ? "active" : "inactive"}">${esc(labels[request.status] || request.status)}</span></td></tr>`; }).join("") || emptyRow(9, "Nenhuma solicitação recebida.");
  document.querySelectorAll(".request-check").forEach((box) => box.addEventListener("change", () => { box.checked ? state.selectedRequests.add(box.dataset.request) : state.selectedRequests.delete(box.dataset.request); updateRequestButtons(); }));
  $("request-check-all").checked = false;
  updateRequestButtons();
}

function updateRequestButtons() {
  $("approve-requests").disabled = !state.selectedRequests.size;
  $("reject-requests").disabled = !state.selectedRequests.size;
}

async function loadRequests() {
  const { data, error } = await supabase.from("device_enrollment_requests").select("id,hostname,mac_addresses,local_ip_addresses,request_ip,os_type,os_version,agent_version,status,last_requested_at,matched_device_id,match_score,match_reasons").order("last_requested_at", { ascending: false }).limit(200);
  if (error) return message("Não foi possível carregar as solicitações.", true);
  state.requests = data || [];
  renderRequests();
}

async function decideRequests(status) {
  if (!state.selectedRequests.size) return;
  const { error } = await supabase.from("device_enrollment_requests").update({ status }).in("id", [...state.selectedRequests]);
  if (error) return message("Não foi possível atualizar as solicitações.", true);
  message(status === "approved" ? "Computadores autorizados. Cadastros reconhecidos serão atualizados sem duplicação." : "Solicitações recusadas.");
  state.selectedRequests.clear();
  await loadRequests();
}

function renderSoftware() { const query = $("software-search").value.trim().toLowerCase(); const device = $("software-device").value; const rows = state.software.filter((s) => (!device || s.device_id === device) && (!query || s.name.toLowerCase().includes(query) || (s.publisher || "").toLowerCase().includes(query))); $("software-rows").innerHTML = rows.map((s) => `<tr><td><b>${esc(s.name)}</b></td><td>${esc(s.version)}</td><td>${esc(s.publisher)}</td><td>${esc(s.devices?.hostname)}</td><td>${esc(s.scope)}</td><td>${esc(s.architecture)}</td></tr>`).join("") || emptyRow(6, "Nenhum software encontrado."); }
function bindDeviceChecks() { document.querySelectorAll(".device-check").forEach((box) => box.addEventListener("change", () => { box.checked ? state.selected.add(box.dataset.device) : state.selected.delete(box.dataset.device); document.querySelectorAll(`.device-check[data-device="${CSS.escape(box.dataset.device)}"]`).forEach((peer) => { peer.checked = box.checked; }); $("inventory-refresh").disabled = !state.selected.size; $("send-update").disabled = !state.remoteUpdatesEnabled || !state.selected.size || !$("release-select").value; })); $("inventory-refresh").disabled = !state.selected.size; $("send-update").disabled = !state.remoteUpdatesEnabled || !state.selected.size || !$("release-select").value; }

async function createJob(type, releaseId) {
  if (!state.selected.size) return;
  const { error } = await supabase.rpc("create_device_job", { job_type: type, device_ids: [...state.selected], release_id: releaseId || null });
  if (error) return message(type === "agent_update" && !state.remoteUpdatesEnabled ? "Habilite as atualizações remotas antes de enviar." : "Não foi possível criar a tarefa.", true);
  message("Tarefa criada. Os computadores executarão na próxima sincronização."); await loadData();
}

async function adminFunction(action, payload = {}) { const { data, error } = await supabase.functions.invoke(config.adminFunctionName || "admin-users", { body: { action, ...payload } }); if (error) throw error; return data; }
async function loadUsers() { try { const data = await adminFunction("list"); message(""); $("user-rows").innerHTML = (data.users || []).map((u) => `<tr><td><b>${esc(u.full_name)}</b></td><td>${esc(u.email)}</td><td><span class="badge ${esc(u.role)}">${u.role === "admin" ? "Administrador" : "Monitor"}</span></td><td><span class="badge ${u.active ? "active" : "inactive"}">${u.active ? "Ativo" : "Inativo"}</span></td><td><div class="user-actions"><button class="button user-toggle" data-id="${esc(u.id)}" data-active="${!u.active}" ${u.id === state.profile.id ? "disabled" : ""}>${u.active ? "Desativar" : "Reativar"}</button><button class="button danger user-delete" data-id="${esc(u.id)}" data-name="${esc(u.full_name)}" ${u.id === state.profile.id ? "disabled" : ""}>Remover</button></div></td></tr>`).join("") || emptyRow(5, "Nenhum usuário cadastrado."); document.querySelectorAll(".user-toggle").forEach((button) => button.addEventListener("click", async () => { await adminFunction("update", { userId: button.dataset.id, active: button.dataset.active === "true" }); await loadUsers(); })); document.querySelectorAll(".user-delete").forEach((button) => button.addEventListener("click", async () => { if (!window.confirm(`Remover permanentemente o usuário ${button.dataset.name}?`)) return; try { await adminFunction("delete", { userId: button.dataset.id }); message("Usuário removido permanentemente."); await loadUsers(); } catch { message("Não foi possível remover o usuário. O último administrador não pode ser excluído.", true); } })); } catch { message("Não foi possível carregar os usuários.", true); } }

$("login-form").addEventListener("submit", async (event) => { event.preventDefault(); loginMessage(""); const { data, error } = await supabase.auth.signInWithPassword({ email: $("login-email").value.trim(), password: $("login-password").value }); if (error) return loginMessage("E-mail ou senha inválidos."); await enterApp(data.user); });
$("logout-button").addEventListener("click", async () => { await supabase.auth.signOut(); showLogin(); });
$("navigation").addEventListener("click", (event) => { const button = event.target.closest("button[data-view]"); if (!button) return; document.querySelectorAll(".navigation button,.view").forEach((el) => el.classList.remove("active")); button.classList.add("active"); $(`view-${button.dataset.view}`).classList.add("active"); $("page-title").textContent = $("breadcrumb").textContent = button.childNodes[0].textContent.trim(); if (button.dataset.view === "users") loadUsers(); if (button.dataset.view === "requests") loadRequests(); });
$("software-search").addEventListener("input", renderSoftware); $("software-device").addEventListener("change", renderSoftware); $("release-select").addEventListener("change", () => { $("send-update").disabled = !state.remoteUpdatesEnabled || !state.selected.size || !$("release-select").value; });
$("inventory-refresh").addEventListener("click", () => createJob("inventory_refresh")); $("send-update").addEventListener("click", () => createJob("agent_update", $("release-select").value));
$("toggle-remote-updates").addEventListener("click", async () => { const enabled = !state.remoteUpdatesEnabled; const { error } = await supabase.from("system_settings").update({ remote_updates_enabled: enabled, updated_at: new Date().toISOString(), updated_by: state.profile.email }).eq("id", true); if (error) return message("Não foi possível alterar as atualizações remotas.", true); state.remoteUpdatesEnabled = enabled; message(enabled ? "Atualizações remotas habilitadas." : "Atualizações remotas desabilitadas."); render(); });
$("request-check-all").addEventListener("change", (event) => { document.querySelectorAll(".request-check:not(:disabled)").forEach((box) => { box.checked = event.target.checked; box.checked ? state.selectedRequests.add(box.dataset.request) : state.selectedRequests.delete(box.dataset.request); }); updateRequestButtons(); });
$("approve-requests").addEventListener("click", () => decideRequests("approved"));
$("reject-requests").addEventListener("click", () => decideRequests("rejected"));
$("save-retention").addEventListener("click", async () => { const { error } = await supabase.from("system_settings").update({ event_retention_days: Number($("retention-days").value), updated_at: new Date().toISOString(), updated_by: state.profile.email }).eq("id", true); message(error ? "Não foi possível salvar a política." : "Política de retenção salva.", Boolean(error)); });
$("user-form").addEventListener("submit", async (event) => { event.preventDefault(); try { await adminFunction("create", { fullName: $("user-name").value.trim(), email: $("user-email").value.trim(), password: $("user-password").value, role: $("user-role").value }); event.target.reset(); message("Usuário cadastrado com sucesso."); await loadUsers(); } catch { message("Não foi possível cadastrar. Confira o e-mail institucional e a senha.", true); } });

start();
