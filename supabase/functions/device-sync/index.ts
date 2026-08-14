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

function strings(value: unknown, limit = 16) {
  return Array.isArray(value)
    ? [...new Set(value.map((item) => String(item).trim()).filter(Boolean))].slice(0, limit)
    : [];
}

function requestIp(request: Request) {
  return (request.headers.get("x-forwarded-for")?.split(",")[0] ?? request.headers.get("cf-connecting-ip") ?? "").trim().slice(0, 128) || null;
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
    if (body.action === "request_enrollment") {
      const registrationSecret = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
      const installationId = String(body.installationId ?? "").trim();
      const hostname = String(body.hostname ?? "").trim().slice(0, 255);
      const machineUuidHash = String(body.machineUuidHash ?? "").trim().slice(0, 64);
      if (registrationSecret.length < 32 || !installationId || !hostname || !machineUuidHash) {
        return json({ error: "invalid_enrollment_request" }, 400);
      }

      const registrationHash = await sha256(registrationSecret);
      const metadata = {
        hostname,
        machine_uuid_hash: machineUuidHash,
        mac_addresses: strings(body.macAddresses),
        local_ip_addresses: strings(body.localIpAddresses),
        request_ip: requestIp(request),
        os_type: String(body.osType ?? "Windows").slice(0, 64),
        os_version: String(body.osVersion ?? "").slice(0, 255) || null,
        agent_version: String(body.agentVersion ?? "unknown").slice(0, 64),
        last_requested_at: new Date().toISOString(),
      };
      let { data: enrollment } = await db.from("device_enrollment_requests").select("*")
        .eq("installation_id", installationId).maybeSingle();

      if (!enrollment) {
        const created = await db.from("device_enrollment_requests").insert({
          installation_id: installationId,
          request_secret_hash: registrationHash,
          ...metadata,
        }).select("*").single();
        if (created.error || !created.data) return json({ error: "enrollment_request_failed" }, 409);
        enrollment = created.data;
      } else {
        if (enrollment.request_secret_hash !== registrationHash) return json({ error: "enrollment_request_conflict" }, 409);
        const refreshed = await db.from("device_enrollment_requests").update(metadata)
          .eq("id", enrollment.id).eq("request_secret_hash", registrationHash).select("*").single();
        if (refreshed.error || !refreshed.data) return json({ error: "enrollment_request_failed" }, 409);
        enrollment = refreshed.data;
      }

      if (enrollment.status === "pending") return json({ enrollmentStatus: "pending", requestId: enrollment.id }, 202);
      if (enrollment.status === "rejected") return json({ enrollmentStatus: "rejected", requestId: enrollment.id }, 403);
      if (enrollment.status === "claimed" && enrollment.device_id) {
        const { data: claimedDevice } = await db.from("devices").select("id,device_secret_hash,status")
          .eq("id", enrollment.device_id).maybeSingle();
        if (claimedDevice?.device_secret_hash === registrationHash && claimedDevice.status !== "disabled") {
          return json({ enrollmentStatus: "authorized", deviceId: claimedDevice.id });
        }
        return json({ error: "enrollment_claim_invalid" }, 409);
      }
      if (enrollment.status !== "approved") return json({ error: "invalid_enrollment_status" }, 409);

      const { data: existingDevice } = await db.from("devices").select("id,device_secret_hash,status")
        .eq("installation_id", installationId).maybeSingle();
      let device = existingDevice;
      if (device && device.device_secret_hash !== registrationHash) return json({ error: "device_identity_conflict" }, 409);
      if (!device) {
        const createdDevice = await db.from("devices").insert({
          installation_id: installationId,
          hostname,
          device_secret_hash: registrationHash,
          agent_version: metadata.agent_version,
          os_type: metadata.os_type,
          os_version: metadata.os_version,
          primary_mac: metadata.mac_addresses[0] ?? null,
          mac_addresses: metadata.mac_addresses,
          local_ip_addresses: metadata.local_ip_addresses,
          public_ip: metadata.request_ip,
        }).select("id,device_secret_hash,status").single();
        if (createdDevice.error || !createdDevice.data) return json({ error: "device_registration_failed" }, 409);
        device = createdDevice.data;
      }
      await db.from("device_enrollment_requests").update({
        status: "claimed", claimed_at: new Date().toISOString(), device_id: device.id,
      }).eq("id", enrollment.id).eq("status", "approved");
      return json({ enrollmentStatus: "authorized", deviceId: device.id });
    }

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
      os_type: String(body.osType ?? "Windows").slice(0, 64),
      os_version: String(body.osVersion ?? "").slice(0, 255) || null,
      primary_mac: strings(body.macAddresses)[0] ?? null,
      mac_addresses: strings(body.macAddresses), local_ip_addresses: strings(body.localIpAddresses),
      public_ip: requestIp(request), updated_at: new Date().toISOString(), status: "online",
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
