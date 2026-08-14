import { createClient } from "npm:@supabase/supabase-js@2";

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json; charset=utf-8" },
});

async function sha256(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomSecret() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  let secretKey = Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!secretKey && Deno.env.get("SUPABASE_SECRET_KEYS")) {
    try { secretKey = Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!))[0] as string; } catch { /* configuração inválida */ }
  }
  if (!supabaseUrl || !secretKey) return json({ error: "server_not_configured" }, 500);
  const db = createClient(supabaseUrl, secretKey, { auth: { persistSession: false } });

  try {
    const body = await request.json();
    if (body.action === "enroll") {
      if (!body.enrollmentToken || !body.installationId || !body.hostname) return json({ error: "invalid_enrollment" }, 400);
      const tokenHash = await sha256(String(body.enrollmentToken));
      const { data: token } = await db.from("enrollment_tokens").select("id,expires_at,used_at")
        .eq("token_hash", tokenHash).maybeSingle();
      if (!token || token.used_at || (token.expires_at && new Date(token.expires_at) <= new Date())) {
        return json({ error: "enrollment_denied" }, 403);
      }
      const { data: claimed } = await db.from("enrollment_tokens").update({ used_at: new Date().toISOString() })
        .eq("id", token.id).is("used_at", null).select("id").maybeSingle();
      if (!claimed) return json({ error: "enrollment_already_used" }, 409);
      const deviceSecret = randomSecret();
      const { data: device, error } = await db.from("devices").insert({
        installation_id: String(body.installationId), hostname: String(body.hostname).slice(0, 255),
        device_secret_hash: await sha256(deviceSecret), agent_version: String(body.agentVersion ?? "unknown"),
      }).select("id").single();
      if (error || !device) return json({ error: "enrollment_failed" }, 409);
      await db.from("enrollment_tokens").update({ used_by: device.id }).eq("id", token.id);
      return json({ deviceId: device.id, deviceSecret });
    }

    if (body.action !== "sync") return json({ error: "invalid_action" }, 400);
    const deviceId = request.headers.get("x-device-id");
    const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
    if (!deviceId || !bearer) return json({ error: "device_auth_required" }, 401);
    const { data: device } = await db.from("devices").select("id,device_secret_hash,status")
      .eq("id", deviceId).maybeSingle();
    if (!device || device.status === "disabled" || device.device_secret_hash !== await sha256(bearer)) {
      return json({ error: "device_auth_denied" }, 403);
    }

    await db.from("devices").update({
      hostname: String(body.hostname ?? "unknown").slice(0, 255),
      agent_version: String(body.agentVersion ?? "unknown"), last_seen_at: new Date().toISOString(),
      updated_at: new Date().toISOString(), status: "online",
    }).eq("id", deviceId);

    for (const item of Array.isArray(body.items) ? body.items : []) {
      if (item.kind === "event" && item.payload?.eventId) {
        const e = item.payload;
        await db.from("device_events").upsert({
          event_id: e.eventId, device_id: deviceId, occurred_at: e.timestampUtc,
          event_type: e.type, session_key: e.sessionKey, session_id: e.sessionId,
          user_name: e.user, payload: e.data ?? {},
        }, { onConflict: "event_id", ignoreDuplicates: true });
      } else if (item.kind === "job_result" && item.payload?.jobId) {
        await db.from("device_jobs").update({
          status: item.payload.status === "succeeded" ? "succeeded" : "failed",
          completed_at: new Date().toISOString(), result: item.payload,
        }).eq("job_id", item.payload.jobId).eq("device_id", deviceId);
      }
    }

    if (body.inventory?.software && body.inventory.inventoryHash) {
      const now = new Date().toISOString();
      const rows = body.inventory.software.map((s: Record<string, unknown>) => ({
        device_id: deviceId, inventory_key: s.inventoryKey, name: s.name, version: s.version,
        publisher: s.publisher, install_date: s.installDate, scope: s.scope,
        architecture: s.architecture, product_code: s.productCode,
        estimated_size_kb: s.estimatedSizeKb, last_seen_at: now,
      }));
      if (rows.length) await db.from("software_inventory").upsert(rows, { onConflict: "device_id,inventory_key" });
      const { data: existing } = await db.from("software_inventory").select("inventory_key").eq("device_id", deviceId);
      const current = new Set(rows.map((r: { inventory_key: string }) => r.inventory_key));
      const removed = (existing ?? []).filter((r) => !current.has(r.inventory_key)).map((r) => r.inventory_key);
      if (removed.length) await db.from("software_inventory").delete().eq("device_id", deviceId).in("inventory_key", removed);
      await db.from("devices").update({
        inventory_collected_at: body.inventory.collectedAtUtc, inventory_hash: body.inventory.inventoryHash,
      }).eq("id", deviceId);
    }

    const leaseCutoff = new Date(Date.now() - 15 * 60 * 1000).toISOString();
    await db.from("device_jobs").update({ status: "pending", leased_at: null })
      .eq("device_id", deviceId).eq("status", "leased").lt("leased_at", leaseCutoff);
    const { data: targets } = await db.from("device_jobs")
      .select("job_id,jobs!inner(id,type,payload,expires_at,cancelled_at)")
      .eq("device_id", deviceId).eq("status", "pending").limit(10);
    const jobs = [];
    for (const target of targets ?? []) {
      const job = target.jobs as unknown as { id: string; type: string; payload: Record<string, unknown>; expires_at?: string; cancelled_at?: string };
      if (job.cancelled_at || (job.expires_at && new Date(job.expires_at) <= new Date())) continue;
      const payload = { ...(job.payload ?? {}) };
      if (job.type === "agent_update" && payload.releaseId) {
        const { data: release } = await db.from("agent_releases").select("version,storage_path,sha256,active")
          .eq("id", payload.releaseId).eq("active", true).maybeSingle();
        if (!release) continue;
        const { data: signed } = await db.storage.from("agent-releases").createSignedUrl(release.storage_path, 900);
        if (!signed?.signedUrl) continue;
        Object.assign(payload, { version: release.version, sha256: release.sha256, downloadUrl: signed.signedUrl });
      }
      await db.from("device_jobs").update({ status: "leased", leased_at: new Date().toISOString() })
        .eq("job_id", job.id).eq("device_id", deviceId).eq("status", "pending");
      jobs.push({ id: job.id, type: job.type, payload });
    }
    return json({ accepted: true, jobs });
  } catch (error) {
    console.error(error);
    return json({ error: "internal_error" }, 500);
  }
});
