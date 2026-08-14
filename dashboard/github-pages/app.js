import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const config = window.LABMONITOR_CONFIG || {};
const configured = /^https:\/\/.+\.supabase\.co$/.test(config.supabaseUrl || "") && !String(config.publishableKey || "").includes("SUBSTITUA");
const supabase = configured ? createClient(config.supabaseUrl, config.publishableKey, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } }) : null;
const $ = (id) => document.getElementById(id);
const state = { profile: null, devices: [], events: [], software: [], releases: [], jobs: [], selected: new Set(), retentionDays: 90 };
const eventLabels = { ProhibitedApplicationDetected: "Aplicativo proibido detectado", SessionLocked: "Sessão bloqueada", SessionUnlocked: "Sessão desbloqueada", SessionStarted: "Login registrado", SessionEnded: "Logout registrado" };
const esc = (value) => String(value ?? "—").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const eventName = (value) => eventLabels[value] || value;
const isOnline = (device) => Date.now() - new Date(device.last_seen_at).getTime() < 300000;
const ago = (iso) => { const minutes = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000)); return minutes < 1 ? "agora" : minutes < 60 ? `há ${minutes} min` : minutes < 1440 ? `há ${Math.round(minutes / 60)} h` : `há ${Math.round(minutes / 1440)} d`; };

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
  const results = await Promise.all([
    supabase.from("devices").select("id,hostname,agent_version,status,last_seen_at,inventory_collected_at,os_type,os_version").order("hostname"),
    supabase.from("device_events").select("event_id,occurred_at,event_type,user_name,payload,devices(hostname)").order("occurred_at", { ascending: false }).limit(100),
    supabase.from("software_inventory").select("device_id,inventory_key,name,version,publisher,scope,architecture,devices(hostname)").order("name").limit(5000),
    supabase.from("agent_releases").select("id,version,active,created_at").order("created_at", { ascending: false }),
    supabase.from("device_jobs").select("status,leased_at,completed_at,result,devices(hostname),jobs(type,created_at)").order("leased_at", { ascending: false, nullsFirst: false }).limit(50),
    supabase.from("system_settings").select("event_retention_days").eq("id", true).maybeSingle()
  ]);
  const failed = results.find((item) => item.error);
  if (failed) { message("Não foi possível carregar os dados. Verifique a configuração do Supabase.", true); return; }
  [state.devices, state.events, state.software, state.releases, state.jobs] = results.slice(0, 5).map((item) => item.data || []);
  state.retentionDays = results[5].data?.event_retention_days || 90;
  render();
}

function render() {
  const counts = new Map(); state.software.forEach((s) => counts.set(s.device_id, (counts.get(s.device_id) || 0) + 1));
  $("metric-devices").textContent = state.devices.length; $("metric-online").textContent = state.devices.filter(isOnline).length;
  $("metric-alerts").textContent = state.events.filter((e) => e.event_type === "ProhibitedApplicationDetected" && Date.now() - new Date(e.occurred_at) < 86400000).length;
  $("metric-software").textContent = state.software.length;
  $("overview-devices").innerHTML = state.devices.slice(0, 10).map((d) => `<tr><td><b>${esc(d.hostname)}</b></td><td>${esc(d.os_type || "Windows")} ${esc(d.os_version || "")}</td><td><span class="status ${isOnline(d) ? "online" : ""}"><i></i>${isOnline(d) ? "Online" : "Offline"}</span></td><td>v${esc(d.agent_version)}</td></tr>`).join("") || emptyRow(4, "Nenhum computador cadastrado.");
  $("recent-events").innerHTML = state.events.slice(0, 6).map((e) => `<div class="event-item"><b>${esc(eventName(e.event_type))}</b><small>${esc(e.devices?.hostname)} • ${esc(e.user_name || "SYSTEM")} • ${ago(e.occurred_at)}</small></div>`).join("") || '<div class="empty">Nenhum evento recebido.</div>';
  $("device-rows").innerHTML = state.devices.map((d) => `<tr><td><input class="device-check" type="checkbox" aria-label="Selecionar ${esc(d.hostname)}" data-device="${esc(d.id)}" ${state.profile.role !== "admin" ? "disabled" : ""}></td><td><b>${esc(d.hostname)}</b></td><td>${esc(d.os_type || "Windows")} ${esc(d.os_version || "")}</td><td><span class="status ${isOnline(d) ? "online" : ""}"><i></i>${isOnline(d) ? "Online" : "Offline"}</span></td><td>v${esc(d.agent_version)}</td><td>${counts.get(d.id) || 0}</td><td>${ago(d.last_seen_at)}</td></tr>`).join("") || emptyRow(7, "Nenhum computador cadastrado.");
  $("event-count").textContent = `${state.events.length} eventos`; $("event-rows").innerHTML = state.events.map((e) => `<tr><td>${new Date(e.occurred_at).toLocaleString("pt-BR")}</td><td><span class="badge ${e.event_type === "ProhibitedApplicationDetected" ? "alert" : ""}">${esc(eventName(e.event_type))}</span></td><td>${esc(e.devices?.hostname)}</td><td>${esc(e.user_name || "SYSTEM")}</td><td>${esc(e.payload?.displayName || e.payload?.processName || "—")}</td></tr>`).join("") || emptyRow(5, "Nenhuma ocorrência recebida.");
  $("software-device").innerHTML = '<option value="">Todos os computadores</option>' + state.devices.map((d) => `<option value="${esc(d.id)}">${esc(d.hostname)}</option>`).join("");
  $("inventory-count").textContent = `${state.software.length} instalações`; renderSoftware();
  $("release-select").innerHTML = '<option value="">Selecione uma versão</option>' + state.releases.filter((r) => r.active).map((r) => `<option value="${esc(r.id)}">Versão ${esc(r.version)}</option>`).join("");
  $("job-rows").innerHTML = state.jobs.map((j) => `<tr><td>${esc(j.devices?.hostname)}</td><td>${j.jobs?.type === "agent_update" ? "Atualizar agente" : "Atualizar inventário"}</td><td><span class="badge">${esc(j.status)}</span></td><td>${j.leased_at ? new Date(j.leased_at).toLocaleString("pt-BR") : "Aguardando"}</td><td>${esc(j.result?.message || "—")}</td></tr>`).join("") || emptyRow(5, "Nenhuma tarefa enviada.");
  $("retention-days").value = String(state.retentionDays);
  bindDeviceChecks();
}

function renderSoftware() { const query = $("software-search").value.trim().toLowerCase(); const device = $("software-device").value; const rows = state.software.filter((s) => (!device || s.device_id === device) && (!query || s.name.toLowerCase().includes(query) || (s.publisher || "").toLowerCase().includes(query))); $("software-rows").innerHTML = rows.map((s) => `<tr><td><b>${esc(s.name)}</b></td><td>${esc(s.version)}</td><td>${esc(s.publisher)}</td><td>${esc(s.devices?.hostname)}</td><td>${esc(s.scope)}</td><td>${esc(s.architecture)}</td></tr>`).join("") || emptyRow(6, "Nenhum software encontrado."); }
function bindDeviceChecks() { document.querySelectorAll(".device-check").forEach((box) => box.addEventListener("change", () => { box.checked ? state.selected.add(box.dataset.device) : state.selected.delete(box.dataset.device); $("inventory-refresh").disabled = !state.selected.size; $("send-update").disabled = !state.selected.size || !$("release-select").value; })); }

async function createJob(type, releaseId) {
  if (!state.selected.size) return;
  const { error } = await supabase.rpc("create_device_job", { job_type: type, device_ids: [...state.selected], release_id: releaseId || null });
  if (error) return message("Não foi possível criar a tarefa.", true);
  message("Tarefa criada. Os computadores executarão na próxima sincronização."); await loadData();
}

async function adminFunction(action, payload = {}) { const { data, error } = await supabase.functions.invoke(config.adminFunctionName || "admin-users", { body: { action, ...payload } }); if (error) throw error; return data; }
async function loadUsers() { try { const data = await adminFunction("list"); $("user-rows").innerHTML = (data.users || []).map((u) => `<tr><td><b>${esc(u.full_name)}</b></td><td>${esc(u.email)}</td><td><span class="badge ${esc(u.role)}">${u.role === "admin" ? "Administrador" : "Monitor"}</span></td><td><span class="badge ${u.active ? "active" : "inactive"}">${u.active ? "Ativo" : "Inativo"}</span></td><td><button class="button user-toggle" data-id="${esc(u.id)}" data-active="${!u.active}" ${u.id === state.profile.id ? "disabled" : ""}>${u.active ? "Desativar" : "Reativar"}</button></td></tr>`).join("") || emptyRow(5, "Nenhum usuário cadastrado."); document.querySelectorAll(".user-toggle").forEach((button) => button.addEventListener("click", async () => { await adminFunction("update", { userId: button.dataset.id, active: button.dataset.active === "true" }); await loadUsers(); })); } catch { message("Não foi possível carregar os usuários.", true); } }

$("login-form").addEventListener("submit", async (event) => { event.preventDefault(); loginMessage(""); const { data, error } = await supabase.auth.signInWithPassword({ email: $("login-email").value.trim(), password: $("login-password").value }); if (error) return loginMessage("E-mail ou senha inválidos."); await enterApp(data.user); });
$("logout-button").addEventListener("click", async () => { await supabase.auth.signOut(); showLogin(); });
$("navigation").addEventListener("click", (event) => { const button = event.target.closest("button[data-view]"); if (!button) return; document.querySelectorAll(".navigation button,.view").forEach((el) => el.classList.remove("active")); button.classList.add("active"); $(`view-${button.dataset.view}`).classList.add("active"); $("page-title").textContent = $("breadcrumb").textContent = button.textContent.trim(); if (button.dataset.view === "users") loadUsers(); });
$("software-search").addEventListener("input", renderSoftware); $("software-device").addEventListener("change", renderSoftware); $("release-select").addEventListener("change", () => { $("send-update").disabled = !state.selected.size || !$("release-select").value; });
$("inventory-refresh").addEventListener("click", () => createJob("inventory_refresh")); $("send-update").addEventListener("click", () => createJob("agent_update", $("release-select").value));
$("save-retention").addEventListener("click", async () => { const { error } = await supabase.from("system_settings").update({ event_retention_days: Number($("retention-days").value), updated_at: new Date().toISOString(), updated_by: state.profile.email }).eq("id", true); message(error ? "Não foi possível salvar a política." : "Política de retenção salva.", Boolean(error)); });
$("user-form").addEventListener("submit", async (event) => { event.preventDefault(); try { await adminFunction("create", { fullName: $("user-name").value.trim(), email: $("user-email").value.trim(), password: $("user-password").value, role: $("user-role").value }); event.target.reset(); message("Usuário cadastrado com sucesso."); await loadUsers(); } catch { message("Não foi possível cadastrar. Confira o e-mail institucional e a senha.", true); } });

start();
