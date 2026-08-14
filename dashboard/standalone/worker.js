const JSON_HEADERS = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
const INITIAL_ADMIN_EMAIL = "gabriel.barros@ifms.edu.br";
const INITIAL_ADMIN_NAME = "Gabriel da Silva Barros";

const demo = {
  configured: false,
  retentionDays: 90,
  devices: [
    { id: "1", hostname: "LAB01-PC01", agent_version: "2.0.0", last_seen_at: new Date().toISOString(), software_count: 47 },
    { id: "2", hostname: "LAB01-PC07", agent_version: "2.0.0", last_seen_at: new Date(Date.now() - 120000).toISOString(), software_count: 44 },
    { id: "3", hostname: "LAB02-PC12", agent_version: "1.0.0", last_seen_at: new Date(Date.now() - 86400000).toISOString(), software_count: 39 },
  ],
  events: [
    { event_id: "e1", occurred_at: new Date(Date.now() - 180000).toISOString(), event_type: "Aplicativo proibido", user_name: "IFMS\\ana.silva", hostname: "LAB01-PC07", detail: "Roblox" },
    { event_id: "e2", occurred_at: new Date(Date.now() - 720000).toISOString(), event_type: "Sessão bloqueada", user_name: "IFMS\\aluno.teste", hostname: "LAB01-PC01", detail: "—" },
  ],
  softwareTotal: 130,
};

function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: JSON_HEADERS });
}

const bytesToBase64 = (bytes) => btoa(String.fromCharCode(...bytes));
const base64ToBytes = (value) => Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
async function derivePassword(password, salt) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: base64ToBytes(salt), iterations: 100000 }, key, 256);
  return bytesToBase64(new Uint8Array(bits));
}
async function sha256(value) {
  return bytesToBase64(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}
function randomBase64(size = 32) { const bytes = new Uint8Array(size); crypto.getRandomValues(bytes); return bytesToBase64(bytes); }
function constantTimeEqual(a, b) { if (!a || !b || a.length !== b.length) return false; let diff = 0; for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i); return diff === 0; }
function cookieValue(request, name) {
  const item = (request.headers.get("cookie") || "").split(";").map((x) => x.trim()).find((x) => x.startsWith(`${name}=`));
  return item ? decodeURIComponent(item.slice(name.length + 1)) : null;
}

async function initializeDb(env) {
  if (!env.DB) throw new Error("Banco de usuários indisponível");
  await env.DB.prepare(`CREATE TABLE IF NOT EXISTS app_users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE COLLATE NOCASE,
    display_name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('admin','monitor')),
    active INTEGER NOT NULL DEFAULT 1,
    password_hash TEXT,
    password_salt TEXT,
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    locked_until TEXT,
    created_at TEXT NOT NULL,
    created_by TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )`).run();
  await env.DB.prepare("CREATE INDEX IF NOT EXISTS idx_app_users_active_role ON app_users(active, role)").run();
  await env.DB.prepare(`CREATE TABLE IF NOT EXISTS auth_sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL
  )`).run();
  await env.DB.prepare("CREATE INDEX IF NOT EXISTS idx_auth_sessions_token_expiry ON auth_sessions(token_hash, expires_at)").run();
  await env.DB.prepare("PRAGMA optimize").run();
  const now = new Date().toISOString();
  await env.DB.prepare(`INSERT OR IGNORE INTO app_users
      (id,email,display_name,role,active,created_at,created_by,updated_at)
      VALUES (?,?,?,?,1,?,?,?)`).bind("admin-gabriel", INITIAL_ADMIN_EMAIL, INITIAL_ADMIN_NAME, "admin", now, "system", now).run();
  if (env.INITIAL_ADMIN_PASSWORD_HASH && env.INITIAL_ADMIN_PASSWORD_SALT) {
    const admin = await env.DB.prepare("SELECT password_hash AS passwordHash FROM app_users WHERE id='admin-gabriel'").first();
    if (!constantTimeEqual(admin?.passwordHash, env.INITIAL_ADMIN_PASSWORD_HASH)) {
      await env.DB.prepare("UPDATE app_users SET password_hash=?,password_salt=?,failed_attempts=0,locked_until=NULL,updated_at=? WHERE id='admin-gabriel'")
        .bind(env.INITIAL_ADMIN_PASSWORD_HASH, env.INITIAL_ADMIN_PASSWORD_SALT, now).run();
    }
  }
}

async function currentUser(request, env) {
  if (!env.DB) return { user: null };
  await initializeDb(env);
  const token = cookieValue(request, "lm_session");
  if (!token) return { user: null };
  const user = await env.DB.prepare(`SELECT u.id,u.email,u.display_name AS displayName,u.role,u.active
    FROM auth_sessions s JOIN app_users u ON u.id=s.user_id
    WHERE s.token_hash=? AND s.expires_at>? LIMIT 1`).bind(await sha256(token), new Date().toISOString()).first();
  return { user: user && Number(user.active) === 1 ? user : null };
}

async function requireUser(request, env, role) {
  const auth = await currentUser(request, env);
  if (!auth.user) return { error: json({ error: "access_denied" }, 403) };
  if (role && auth.user.role !== role) return { error: json({ error: "admin_required" }, 403) };
  return auth;
}

async function login(request, env) {
  await initializeDb(env);
  const form = await request.formData();
  const email = String(form.get("email") || "").trim().toLowerCase();
  const password = String(form.get("password") || "");
  const user = await env.DB.prepare(`SELECT id,email,password_hash AS passwordHash,password_salt AS passwordSalt,active,
    failed_attempts AS failedAttempts,locked_until AS lockedUntil FROM app_users WHERE email=? COLLATE NOCASE LIMIT 1`).bind(email).first();
  const now = Date.now();
  if (!user || Number(user.active) !== 1 || (user.lockedUntil && new Date(user.lockedUntil).getTime() > now)) {
    return Response.redirect(new URL("/?erro=credenciais", request.url), 303);
  }
  const candidate = user.passwordSalt ? await derivePassword(password, user.passwordSalt) : "";
  if (!constantTimeEqual(candidate, user.passwordHash)) {
    const failures = Number(user.failedAttempts || 0) + 1;
    const lockedUntil = failures >= 5 ? new Date(now + 15 * 60 * 1000).toISOString() : null;
    await env.DB.prepare("UPDATE app_users SET failed_attempts=?,locked_until=?,updated_at=? WHERE id=?")
      .bind(failures >= 5 ? 0 : failures, lockedUntil, new Date().toISOString(), user.id).run();
    return Response.redirect(new URL("/?erro=credenciais", request.url), 303);
  }
  await env.DB.prepare("UPDATE app_users SET failed_attempts=0,locked_until=NULL,updated_at=? WHERE id=?")
    .bind(new Date().toISOString(), user.id).run();
  const token = randomBase64(32);
  await env.DB.prepare("DELETE FROM auth_sessions WHERE expires_at<=?").bind(new Date().toISOString()).run();
  await env.DB.prepare("INSERT INTO auth_sessions(id,user_id,token_hash,expires_at,created_at) VALUES(?,?,?,?,?)")
    .bind(crypto.randomUUID(), user.id, await sha256(token), new Date(now + 12 * 60 * 60 * 1000).toISOString(), new Date().toISOString()).run();
  return new Response(null, { status: 303, headers: {
    Location: new URL("/", request.url).toString(),
    "Set-Cookie": `lm_session=${encodeURIComponent(token)}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=43200`,
  } });
}

async function logout(request, env) {
  const token = cookieValue(request, "lm_session");
  if (token && env.DB) await env.DB.prepare("DELETE FROM auth_sessions WHERE token_hash=?").bind(await sha256(token)).run();
  return new Response(null, { status: 303, headers: {
    Location: new URL("/", request.url).toString(),
    "Set-Cookie": "lm_session=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0",
  } });
}

async function rest(env, path, options = {}) {
  const key = env.SUPABASE_SECRET_KEY;
  return fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, {
    ...options,
    headers: { apikey: key, Authorization: `Bearer ${key}`, "content-type": "application/json", ...(options.headers || {}) },
  });
}

async function dashboard(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SECRET_KEY) return demo;
  try {
    const [d, e, s, c] = await Promise.all([
      rest(env, "devices?select=id,hostname,agent_version,last_seen_at&order=hostname"),
      rest(env, "device_events?select=event_id,occurred_at,event_type,user_name,payload,devices(hostname)&order=occurred_at.desc&limit=50"),
      rest(env, "system_settings?select=event_retention_days&id=eq.true&limit=1"),
      rest(env, "software_inventory?select=device_id,inventory_key"),
    ]);
    if (!d.ok || !e.ok) return demo;
    const devices = await d.json();
    const events = await e.json();
    const settings = s.ok ? await s.json() : [];
    const inventory = c.ok ? await c.json() : [];
    const counts = {};
    inventory.forEach((x) => { counts[x.device_id] = (counts[x.device_id] || 0) + 1; });
    return {
      configured: true,
      retentionDays: settings[0]?.event_retention_days || 90,
      softwareTotal: inventory.length,
      devices: devices.map((x) => ({ ...x, software_count: counts[x.id] || 0 })),
      events: events.map((x) => ({
        event_id: x.event_id,
        occurred_at: x.occurred_at,
        event_type: x.event_type,
        user_name: x.user_name,
        hostname: x.devices?.hostname,
        detail: x.payload?.displayName || "—",
      })),
    };
  } catch { return demo; }
}

async function listUsers(request, env) {
  const auth = await requireUser(request, env, "admin");
  if (auth.error) return auth.error;
  const result = await env.DB.prepare(`SELECT id,email,display_name AS displayName,role,active,created_at AS createdAt
    FROM app_users ORDER BY active DESC, role ASC, display_name COLLATE NOCASE`).all();
  return json({ users: result.results || [] });
}

async function createUser(request, env) {
  const auth = await requireUser(request, env, "admin");
  if (auth.error) return auth.error;
  const body = await request.json().catch(() => ({}));
  const name = String(body.name || "").trim();
  const email = String(body.email || "").trim().toLowerCase();
  const role = body.role === "admin" ? "admin" : body.role === "monitor" ? "monitor" : "";
  const password = String(body.password || "");
  if (name.length < 3 || name.length > 120) return json({ error: "invalid_name" }, 400);
  if (!/^[^\s@]+@ifms\.edu\.br$/i.test(email)) return json({ error: "institutional_email_required" }, 400);
  if (!role) return json({ error: "invalid_role" }, 400);
  if (password.length < 10 || password.length > 128) return json({ error: "weak_password" }, 400);
  const now = new Date().toISOString();
  const salt = randomBase64(16);
  const passwordHash = await derivePassword(password, salt);
  await env.DB.prepare(`INSERT INTO app_users
    (id,email,display_name,role,active,password_hash,password_salt,created_at,created_by,updated_at)
    VALUES (?,?,?,?,1,?,?,?,?,?)
    ON CONFLICT(email) DO UPDATE SET display_name=excluded.display_name,role=excluded.role,active=1,password_hash=excluded.password_hash,password_salt=excluded.password_salt,updated_at=excluded.updated_at`)
    .bind(crypto.randomUUID(), email, name, role, passwordHash, salt, now, auth.user.email, now).run();
  return json({ ok: true }, 201);
}

async function updateUser(request, env) {
  const auth = await requireUser(request, env, "admin");
  if (auth.error) return auth.error;
  const body = await request.json().catch(() => ({}));
  const id = String(body.id || "");
  if (!id || id === auth.user.id) return json({ error: "protected_user" }, 400);
  const active = body.active === false ? 0 : 1;
  const role = body.role === "admin" ? "admin" : body.role === "monitor" ? "monitor" : null;
  if (!role) return json({ error: "invalid_role" }, 400);
  await env.DB.prepare("UPDATE app_users SET active=?,role=?,updated_at=? WHERE id=?")
    .bind(active, role, new Date().toISOString(), id).run();
  return json({ ok: true });
}

async function setRetention(request, env) {
  const auth = await requireUser(request, env, "admin");
  if (auth.error) return auth.error;
  if (!env.SUPABASE_URL || !env.SUPABASE_SECRET_KEY) return json({ error: "not_configured" }, 503);
  const body = await request.json().catch(() => ({}));
  const days = Number(body.retentionDays);
  if (!Number.isInteger(days) || days < 7 || days > 3650) return json({ error: "invalid" }, 400);
  const response = await rest(env, "system_settings?id=eq.true", {
    method: "PATCH",
    body: JSON.stringify({ event_retention_days: days, updated_at: new Date().toISOString(), updated_by: auth.user.email }),
  });
  return json({ ok: response.ok }, response.ok ? 200 : 502);
}

const loginHtml = (showError) => `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Entrar • IFMS LabMonitor</title><style>${baseCss}</style></head><body class="loginBody"><main class="loginCard"><div class="ifmsBrand"><div class="ifmsSymbol">${ifmsSymbol}</div><div><strong>IFMS</strong><span>LabMonitor</span></div></div><span class="eyebrow">ACESSO INSTITUCIONAL</span><h1>Gestão segura dos laboratórios</h1><p>Entre com seu e-mail institucional e a senha cadastrada pelo administrador.</p>${showError ? '<div class="loginError">E-mail ou senha inválidos. Após cinco tentativas, o acesso fica bloqueado por 15 minutos.</div>' : ''}<form class="loginForm" method="post" action="/login"><label>E-MAIL</label><input name="email" type="email" autocomplete="username" required placeholder="nome@ifms.edu.br"><label>SENHA</label><input name="password" type="password" autocomplete="current-password" required><button class="loginButton" type="submit">Entrar</button></form><small>As senhas são protegidas por derivação criptográfica e nunca ficam armazenadas em texto legível.</small></main></body></html>`;

const ifmsSymbol = '<i></i><i></i><i></i><i></i><i class="round"></i><i></i><i></i><i></i><i></i>';
const escapeHtml = (value) => String(value ?? "—").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const baseCss = `
:root{--ifms:#2f9e41;--ifms-dark:#176b2b;--ifms-soft:#eaf5ec;--red:#c72c35;--ink:#15231a;--muted:#66736a;--line:#dce6de;--paper:#f4f7f4;--white:#fff}*{box-sizing:border-box}body{margin:0;color:var(--ink);background:var(--paper);font:14px Inter,Segoe UI,Arial,sans-serif}.loginBody{min-height:100vh;display:grid;place-items:center;padding:24px;background:radial-gradient(circle at 85% 10%,#dff0e2,transparent 38%),linear-gradient(145deg,#f7faf7,#eaf2eb)}.loginCard{width:min(520px,100%);background:#fff;border:1px solid var(--line);border-radius:24px;padding:42px;box-shadow:0 24px 70px #16391f18}.ifmsBrand{display:flex;align-items:center;gap:14px}.ifmsBrand strong{display:block;font-size:25px;letter-spacing:.04em}.ifmsBrand span{display:block;color:var(--muted);font-size:13px}.ifmsSymbol{width:45px;display:grid;grid-template-columns:repeat(3,11px);gap:4px}.ifmsSymbol i{width:11px;height:11px;background:var(--ifms);border-radius:2px}.ifmsSymbol .round{background:var(--red);border-radius:50%}.eyebrow{display:inline-block;margin-top:34px;color:var(--ifms-dark);font-size:11px;font-weight:800;letter-spacing:.13em}.eyebrow.red{color:var(--red)}.loginCard h1{font-size:34px;line-height:1.08;margin:12px 0}.loginCard p{color:var(--muted);line-height:1.7}.loginCard small{display:block;color:var(--muted);margin-top:18px;line-height:1.5}.loginForm{display:grid;gap:8px;margin-top:22px}.loginForm label{margin-top:8px;font-size:11px;font-weight:800;color:var(--muted)}.loginForm input{width:100%;padding:13px;border:1px solid var(--line);border-radius:10px;font:inherit}.loginError{padding:11px 13px;border-radius:9px;background:#fbeaec;color:#8b2830;font-size:12px;line-height:1.5}.loginButton{display:block;width:100%;border:0;text-align:center;margin-top:16px;padding:14px 18px;border-radius:11px;color:#fff;background:var(--ifms);text-decoration:none;font:inherit;font-weight:800;cursor:pointer}.loginButton:hover{background:var(--ifms-dark)}.loginButton.secondary{background:#fff;color:var(--ifms-dark);border:1px solid var(--line)}
`;

const appCss = `${baseCss}
.shell{min-height:100vh;display:grid;grid-template-columns:258px 1fr}.side{background:#102d19;color:#fff;padding:26px 17px;position:sticky;top:0;height:100vh}.side .ifmsBrand{margin:0 8px 32px}.side .ifmsBrand span{color:#a9c3af}.side .ifmsSymbol i{background:#52b863}.side .ifmsSymbol .round{background:#e1545c}.nav{display:grid;gap:6px}.nav button{border:0;background:transparent;color:#bed0c2;padding:12px 13px;text-align:left;border-radius:10px;cursor:pointer;font:inherit}.nav button.active,.nav button:hover{background:#20552e;color:#fff}.nav button.hidden{display:none}.navIcon{display:inline-grid;width:24px}.foot{position:absolute;left:25px;bottom:24px;color:#a9c3af;font-size:12px;line-height:1.7}.statusDot{display:inline-block;width:7px;height:7px;border-radius:50%;background:#64d276;margin-right:6px}.top{height:76px;background:#fff;border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;padding:0 34px}.crumb{font-size:12px;color:var(--muted)}.profile{display:flex;align-items:center;gap:11px}.avatar{width:36px;height:36px;border-radius:50%;display:grid;place-items:center;background:var(--ifms-soft);color:var(--ifms-dark);font-weight:900}.profile b,.profile small{display:block}.profile small{color:var(--muted);margin-top:2px}.profile form{margin-left:8px}.profile form button{border:0;background:none;color:var(--ifms-dark);font:inherit;font-size:12px;cursor:pointer}.content{padding:30px 34px;max-width:1480px}.heading{display:flex;justify-content:space-between;align-items:end;margin-bottom:22px}.heading h1{font-size:30px;margin:0 0 6px}.heading p{margin:0;color:var(--muted)}.live,.roleTag,.badge{display:inline-flex;align-items:center;border-radius:999px;padding:7px 10px;font-size:11px;font-weight:800}.live{background:var(--ifms-soft);color:var(--ifms-dark);border:1px solid #c7e4cc}.roleTag{background:#edf2ee;color:#4d5f51}.notice{background:#fff7e7;border:1px solid #ecd39d;color:#6d4c13;padding:12px 15px;border-radius:11px;margin-bottom:16px}.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}.metric,.panel{background:#fff;border:1px solid var(--line);border-radius:15px;box-shadow:0 2px 8px #1737200b}.metric{padding:20px;border-top:3px solid var(--ifms)}.metric span{color:var(--muted);font-size:12px}.metric b{display:block;font-size:29px;margin:16px 0 4px}.cols{display:grid;grid-template-columns:1.4fr .8fr;gap:16px;margin-top:16px}.panelHead{padding:18px 20px;border-bottom:1px solid var(--line);display:flex;align-items:center;justify-content:space-between}.panelHead b{font-size:15px}.panelHead span{font-size:12px;color:var(--muted)}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:13px 18px;border-bottom:1px solid #edf1ee;font-size:12px}th{color:var(--muted);background:#fbfcfb}.dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:#39ad5a;margin-right:7px}.events{padding:7px 20px}.event{padding:13px 0;border-bottom:1px solid #edf1ee}.event b,.event small{display:block}.event small{color:var(--muted);margin-top:4px}.view{display:none}.view.active{display:block}.section{padding:20px}.toolbar{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:18px}.field{display:grid;gap:6px;min-width:180px;flex:1}.field label{font-size:11px;font-weight:800;color:var(--muted)}input,select,.btn{border:1px solid var(--line);background:#fff;padding:11px 12px;border-radius:9px;font:inherit}.btn{font-weight:800;cursor:pointer}.btn.primary{background:var(--ifms);border-color:var(--ifms);color:#fff}.btn.danger{color:var(--red)}.btn:disabled{opacity:.5;cursor:not-allowed}.formGrid{display:grid;grid-template-columns:1.1fr 1.1fr 1fr .7fr auto;gap:12px;align-items:end}.message{margin-top:12px;padding:11px;border-radius:9px;background:var(--ifms-soft);color:var(--ifms-dark)}.badge.admin{background:#e5f3e7;color:var(--ifms-dark)}.badge.monitor{background:#eef1f7;color:#465575}.badge.off{background:#f7e9ea;color:#8b2830}.empty{padding:30px;color:var(--muted);text-align:center}@media(max-width:960px){.shell{grid-template-columns:82px 1fr}.side .ifmsBrand div:last-child,.navLabel,.foot{display:none}.metrics{grid-template-columns:repeat(2,1fr)}.cols{grid-template-columns:1fr}.formGrid{grid-template-columns:1fr 1fr}.content{padding:24px}.top{padding:0 24px}}@media(max-width:640px){.shell{display:block}.side{height:auto;position:static;display:flex;padding:10px;overflow:auto}.side .ifmsBrand{margin:0 12px 0 0}.nav{display:flex}.navLabel{display:inline}.top{padding:0 14px}.profile small,.profile form,.crumb{display:none}.content{padding:20px 14px}.metrics{grid-template-columns:1fr}.formGrid{grid-template-columns:1fr}.heading{align-items:start;gap:12px}.live{display:none}.loginCard{padding:30px 24px}}
`;

function appHtml(user, origin) {
  const initials = user.displayName.split(/\s+/).slice(0, 2).map((x) => x[0]).join("").toUpperCase();
  return `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IFMS LabMonitor</title><meta name="description" content="Gestão e monitoramento dos laboratórios Windows do IFMS"><meta property="og:title" content="IFMS LabMonitor"><meta property="og:description" content="Gestão segura dos laboratórios de informática"><meta property="og:image" content="${origin}/og.png"><meta name="twitter:card" content="summary_large_image"><style>${appCss}</style></head><body><div class="shell"><aside class="side"><div class="ifmsBrand"><div class="ifmsSymbol">${ifmsSymbol}</div><div><strong>IFMS</strong><span>LabMonitor</span></div></div><nav class="nav"><button class="active" data-view="overview"><span class="navIcon">⌂</span><span class="navLabel">Visão geral</span></button><button data-view="events"><span class="navIcon">!</span><span class="navLabel">Ocorrências</span></button><button data-view="retention" data-admin><span class="navIcon">⌛</span><span class="navLabel">Retenção</span></button><button data-view="users" data-admin><span class="navIcon">♙</span><span class="navLabel">Usuários</span></button></nav><div class="foot"><span class="statusDot"></span>Servidor operacional<br>Sincronização a cada 5 min</div></aside><main><header class="top"><span class="crumb">Laboratórios / <b id="crumb">Visão geral</b></span><div class="profile"><span class="avatar">${escapeHtml(initials)}</span><div><b>${escapeHtml(user.displayName)}</b><small>${user.role === "admin" ? "Administrador" : "Monitor"}</small></div><a href="/signout-with-chatgpt?return_to=%2F">Sair</a></div></header><div class="content"><div class="heading"><div><h1 id="title">Visão geral</h1><p>Monitoramento institucional das estações Windows.</p></div><span class="live">● Atualização automática</span></div><div id="notice" class="notice">Modo de demonstração: conecte o Supabase para receber os dados reais.</div><section id="overview" class="view active"><div class="metrics"><div class="metric"><span>Computadores</span><b id="computers">0</b><span>cadastrados</span></div><div class="metric"><span>Online agora</span><b id="online">0</b><span>últimos 5 minutos</span></div><div class="metric"><span>Ocorrências recentes</span><b id="alerts">0</b><span>exigem revisão</span></div><div class="metric"><span>Softwares catalogados</span><b id="software">0</b><span>instalações</span></div></div><div class="cols"><div class="panel"><div class="panelHead"><b>Estado das estações</b><span>última comunicação</span></div><table><thead><tr><th>Computador</th><th>Estado</th><th>Agente</th><th>Softwares</th></tr></thead><tbody id="devices"></tbody></table></div><div class="panel"><div class="panelHead"><b>Atividade recente</b><span>eventos</span></div><div class="events" id="recent"></div></div></div></section><section id="events" class="view"><div class="panel"><div class="panelHead"><b>Registro de ocorrências</b><span>eventos recentes</span></div><table><thead><tr><th>Horário</th><th>Evento</th><th>Computador</th><th>Usuário</th><th>Detalhe</th></tr></thead><tbody id="eventRows"></tbody></table></div></section><section id="retention" class="view"><div class="panel"><div class="panelHead"><b>Retenção dos eventos</b><span>configuração administrativa</span></div><div class="section formGrid"><div><b>Manter ocorrências por</b><p>Máquinas, inventário e versões não são apagados.</p></div><span></span><select id="days"><option>30</option><option>60</option><option selected>90</option><option>180</option><option>365</option></select><button id="saveRetention" class="btn primary">Salvar política</button></div><div id="retentionResult" class="message" hidden></div></div></section><section id="users" class="view"><div class="panel"><div class="panelHead"><b>Usuários autorizados</b><span>administradores e monitores</span></div><div class="section"><form id="userForm" class="formGrid"><div class="field"><label>NOME COMPLETO</label><input id="userName" required minlength="3" placeholder="Professor ou servidor"></div><div class="field"><label>E-MAIL INSTITUCIONAL</label><input id="userEmail" required type="email" placeholder="nome@ifms.edu.br"></div><div class="field"><label>PERFIL</label><select id="userRole"><option value="monitor">Monitor</option><option value="admin">Administrador</option></select></div><button class="btn primary" type="submit">Cadastrar</button></form><div id="userMessage" class="message" hidden></div></div><table><thead><tr><th>Nome</th><th>E-mail</th><th>Perfil</th><th>Estado</th><th>Ação</th></tr></thead><tbody id="userRows"></tbody></table></div></section></div></main></div><script>
const role=${JSON.stringify(user.role)};if(role!=="admin")document.querySelectorAll('[data-admin]').forEach(x=>x.classList.add('hidden'));const esc=s=>String(s??'—').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));let data;async function load(){const r=await fetch('/api/dashboard');if(!r.ok)return;data=await r.json();notice.style.display=data.configured?'none':'block';computers.textContent=data.devices.length;online.textContent=data.devices.filter(d=>Date.now()-new Date(d.last_seen_at)<300000).length;alerts.textContent=data.events.length;software.textContent=data.softwareTotal;devices.innerHTML=data.devices.map(d=>'<tr><td><b>'+esc(d.hostname)+'</b></td><td><span class="dot"></span>'+(Date.now()-new Date(d.last_seen_at)<300000?'Online':'Offline')+'</td><td>v'+esc(d.agent_version)+'</td><td>'+esc(d.software_count)+'</td></tr>').join('');eventRows.innerHTML=data.events.map(e=>'<tr><td>'+new Date(e.occurred_at).toLocaleString('pt-BR')+'</td><td>'+esc(e.event_type)+'</td><td>'+esc(e.hostname)+'</td><td>'+esc(e.user_name)+'</td><td>'+esc(e.detail)+'</td></tr>').join('');recent.innerHTML=data.events.slice(0,5).map(e=>'<div class="event"><b>'+esc(e.event_type)+'</b><small>'+esc(e.hostname)+' • '+esc(e.user_name)+'</small></div>').join('');days.value=data.retentionDays||90}async function loadUsers(){if(role!=="admin")return;const r=await fetch('/api/users');if(!r.ok)return;const body=await r.json();userRows.innerHTML=body.users.map(u=>'<tr><td><b>'+esc(u.displayName)+'</b></td><td>'+esc(u.email)+'</td><td><span class="badge '+u.role+'">'+(u.role==='admin'?'Administrador':'Monitor')+'</span></td><td><span class="badge '+(u.active?'admin':'off')+'">'+(u.active?'Ativo':'Inativo')+'</span></td><td><button class="btn '+(u.active?'danger':'')+'" data-user="'+esc(u.id)+'" data-active="'+(!u.active)+'" data-role="'+esc(u.role)+'" '+(u.id==='owner'?'disabled':'')+'>'+(u.active?'Desativar':'Reativar')+'</button></td></tr>').join('');document.querySelectorAll('[data-user]').forEach(b=>b.onclick=async()=>{await fetch('/api/users',{method:'PATCH',headers:{'content-type':'application/json'},body:JSON.stringify({id:b.dataset.user,active:b.dataset.active==='true',role:b.dataset.role})});loadUsers()})}document.querySelectorAll('.nav button').forEach(b=>b.onclick=()=>{document.querySelectorAll('.nav button,.view').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.getElementById(b.dataset.view).classList.add('active');title.textContent=crumb.textContent=b.textContent.trim();if(b.dataset.view==='users')loadUsers()});if(role==='admin'){userForm.onsubmit=async e=>{e.preventDefault();const r=await fetch('/api/users',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({name:userName.value,email:userEmail.value,role:userRole.value})});userMessage.hidden=false;userMessage.textContent=r.ok?'Usuário cadastrado. O acesso será liberado pelo e-mail institucional.':'Revise o nome e use um e-mail @ifms.edu.br.';if(r.ok){userForm.reset();loadUsers()}};saveRetention.onclick=async()=>{const r=await fetch('/api/settings',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({retentionDays:Number(days.value)})});retentionResult.hidden=false;retentionResult.textContent=r.ok?'Política salva com sucesso.':'O Supabase ainda não está conectado.'}}load();
</script><script>
if(role==='admin'){
  const passwordField=document.createElement('div');
  passwordField.className='field';
  passwordField.innerHTML='<label>SENHA TEMPORÁRIA</label><input id="userPassword" required type="password" minlength="10" autocomplete="new-password" placeholder="Mínimo de 10 caracteres">';
  userForm.insertBefore(passwordField,userRole.parentElement);
  userForm.onsubmit=async e=>{
    e.preventDefault();
    const r=await fetch('/api/users',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({name:userName.value,email:userEmail.value,password:userPassword.value,role:userRole.value})});
    userMessage.hidden=false;
    userMessage.textContent=r.ok?'Usuário cadastrado com senha protegida.':'Revise os dados; use e-mail @ifms.edu.br e senha com pelo menos 10 caracteres.';
    if(r.ok){userForm.reset();loadUsers()}
  };
}
</script></body></html>`;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/og.png" && env.ASSETS) return env.ASSETS.fetch(request);
    if (url.pathname === "/login" && request.method === "POST") return login(request, env);
    if ((url.pathname === "/logout" && request.method === "POST") || url.pathname === "/signout-with-chatgpt") return logout(request, env);
    let auth;
    try { auth = await currentUser(request, env); }
    catch (error) {
      console.error("Falha ao inicializar banco do LabMonitor", error instanceof Error ? error.message : String(error));
      return new Response("Configuração do banco de usuários em andamento.", { status: 503 });
    }
    if (url.pathname.startsWith("/api/")) {
      if (url.pathname === "/api/dashboard") {
        const allowed = await requireUser(request, env);
        return allowed.error || json(await dashboard(env));
      }
      if (url.pathname === "/api/users" && request.method === "GET") return listUsers(request, env);
      if (url.pathname === "/api/users" && request.method === "POST") return createUser(request, env);
      if (url.pathname === "/api/users" && request.method === "PATCH") return updateUser(request, env);
      if (url.pathname === "/api/settings" && request.method === "POST") return setRetention(request, env);
      return json({ error: "not_found" }, 404);
    }
    if (!auth.user) return new Response(loginHtml(url.searchParams.has("erro")), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
    return new Response(appHtml(auth.user, url.origin), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
  },
};
