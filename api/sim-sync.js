// Asset Track Back-Office — 1oT SIM connectivity sync.
//
// Runs as a Vercel serverless function (Node 18+, global fetch). It pulls every
// SIM from the 1oT Terminal API, writes live status into public.sims, and flags
// any SIM with no data session in the last 12 hours as offline — raising a
// diagnostic task (deduped by ICCID) for the team.
//
// Secrets live ONLY in Vercel env vars, never in the browser or git:
//   ONE_OT_API_USERNAME, ONE_OT_API_PASSWORD   (from 1oT -> api-settings)
//   SUPABASE_SERVICE_ROLE_KEY                   (Supabase service role)
//   CRON_SECRET                                 (any long random string)
//
// Callable two ways:
//   1. By the app: Authorization: Bearer <signed-in admin access token>.
//   2. By Vercel Cron: Authorization: Bearer <CRON_SECRET>.

const SUPABASE_URL = "https://mdeotqkdjiylwtmtwtor.supabase.co";
const ONE_OT_BASE  = "https://api.1ot.mobi/v1";
const OFFLINE_HOURS = 12;
const OFFLINE_MS = OFFLINE_HOURS * 3600 * 1000;

function send(res, code, obj){
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(obj));
}
function sleep(ms){ return new Promise(r => setTimeout(r, ms)); }
function iso(ms){ return (ms && ms > 0) ? new Date(ms).toISOString() : null; }

module.exports = async function handler(req, res){
  if(req.method !== "POST" && req.method !== "GET") return send(res, 405, { error: "Method not allowed" });

  const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const OT_USER = process.env.ONE_OT_API_USERNAME;
  const OT_PASS = process.env.ONE_OT_API_PASSWORD;
  const CRON_SECRET = process.env.CRON_SECRET;
  if(!SERVICE_KEY) return send(res, 500, { error: "Add SUPABASE_SERVICE_ROLE_KEY in Vercel env vars." });
  if(!OT_USER || !OT_PASS) return send(res, 500, { error: "Add ONE_OT_API_USERNAME and ONE_OT_API_PASSWORD (from 1oT -> api-settings) in Vercel env vars." });

  // --- authorize caller: admin user token OR the cron secret ---
  const auth = req.headers["authorization"] || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  let authorized = false;
  if(CRON_SECRET && token === CRON_SECRET){
    authorized = true;
  } else if(token){
    const whoRes = await fetch(SUPABASE_URL + "/auth/v1/user", { headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + token } });
    if(whoRes.ok){
      const caller = await whoRes.json();
      const profRes = await fetch(SUPABASE_URL + "/rest/v1/profiles?id=eq." + caller.id + "&select=role", { headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY } });
      const profArr = profRes.ok ? await profRes.json() : [];
      authorized = profArr[0] && profArr[0].role === "admin";
    }
  }
  if(!authorized) return send(res, 401, { error: "Not authorized." });

  // --- 1. get a 1oT access token (rate limited to 1 / 5s) ---
  const q = "username=" + encodeURIComponent(OT_USER) + "&password=" + encodeURIComponent(OT_PASS) + "&grant_type=password";
  const tokRes = await fetch(ONE_OT_BASE + "/oauth/token?" + q, { method: "POST" });
  if(!tokRes.ok){
    const t = await tokRes.text().catch(() => "");
    return send(res, 502, { error: "1oT auth failed (" + tokRes.status + "). Check the API username/password.", detail: t.slice(0, 200) });
  }
  const tokJson = await tokRes.json();
  const accessToken = tokJson.access_token;
  if(!accessToken) return send(res, 502, { error: "1oT returned no access token." });

  // --- 2. page through every SIM ---
  const now = Date.now();
  let offset = 0, total = Infinity, pages = 0;
  const sims = [];
  while(sims.length < total && pages < 100){
    const r = await fetch(ONE_OT_BASE + "/get_sims?offset=" + offset, { headers: { Authorization: accessToken } });
    if(!r.ok){
      const t = await r.text().catch(() => "");
      return send(res, 502, { error: "1oT get_sims failed (" + r.status + ").", detail: t.slice(0, 200) });
    }
    const page = await r.json();
    total = typeof page.total === "number" ? page.total : (page.sims || []).length;
    const batch = page.sims || [];
    if(!batch.length) break;
    sims.push.apply(sims, batch);
    offset += batch.length;
    pages++;
    if(sims.length < total) await sleep(220); // stay under 5 req/s
  }

  // --- 3. build upsert rows + decide which are offline (no data session > 12h) ---
  const rows = [];
  const offlineNow = [];
  sims.forEach(function(s){
    const lastData = s.lastDataSessionMillis || 0;
    const quiet = !lastData || (now - lastData) > OFFLINE_MS;
    const state = quiet ? "offline" : "live";
    rows.push({
      iccid: s.iccid,
      msisdn: s.msisdn || null,
      sim_name: s.name || null,
      network: s.networkName || null,
      state: state,
      last_data_session: iso(lastData),
      last_network_activity: iso(s.lastNetworkActivityMillis),
      last_seen: iso(s.lastNetworkActivityMillis || lastData),
      data_used_mb: s.dataUsedInBytes ? Math.round(s.dataUsedInBytes / 1048.576) / 1000 : 0,
      last_country: s.lastCountry || null,
      synced_at: new Date(now).toISOString(),
      offline_since: quiet ? (iso(lastData) || new Date(now).toISOString()) : null
    });
    if(quiet) offlineNow.push(s);
  });

  // --- 4. upsert into sims (merge-duplicates keeps vehicle/client links) ---
  let upserted = 0;
  for(let i = 0; i < rows.length; i += 200){
    const chunk = rows.slice(i, i + 200);
    const up = await fetch(SUPABASE_URL + "/rest/v1/sims?on_conflict=iccid", {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY, "Content-Type": "application/json", Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify(chunk)
    });
    if(up.ok) upserted += chunk.length;
  }

  // --- 5. raise a diagnostic task for each newly-quiet SIM (deduped by iccid) ---
  let tasksCreated = 0;
  const today = new Date(new Date().toLocaleString("en-US", { timeZone: "Africa/Gaborone" })).toISOString().slice(0, 10);
  for(const s of offlineNow){
    const iccid = s.iccid;
    // skip if an open sim_offline task already exists for this SIM
    const ex = await fetch(SUPABASE_URL + "/rest/v1/tasks?sim_iccid=eq." + encodeURIComponent(iccid) + "&status=neq.done&select=id&limit=1", { headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY } });
    const exArr = ex.ok ? await ex.json() : [];
    if(exArr.length) continue;
    // link to our sims row (for client_id) if we have it
    const simRow = await fetch(SUPABASE_URL + "/rest/v1/sims?iccid=eq." + encodeURIComponent(iccid) + "&select=client_id,vehicle_id&limit=1", { headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY } });
    const simArr = simRow.ok ? await simRow.json() : [];
    const client_id = simArr[0] && simArr[0].client_id ? simArr[0].client_id : null;
    const label = s.name || iccid;
    const mk = await fetch(SUPABASE_URL + "/rest/v1/tasks", {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY, "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify({
        title: "Offline tracker — " + label + " (no data " + OFFLINE_HOURS + "h+)",
        client_id: client_id,
        due_date: today,
        status: "open",
        priority: "urgent",
        recurrence: "none",
        category: "sim_offline",
        sim_iccid: iccid
      })
    });
    if(mk.ok) tasksCreated++;
  }

  return send(res, 200, { ok: true, scanned: sims.length, upserted: upserted, offline: offlineNow.length, tasks_created: tasksCreated });
};
