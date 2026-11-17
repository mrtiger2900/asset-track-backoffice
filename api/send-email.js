// Asset Track Back-Office — email sender (Resend).
//
// Vercel serverless function. Sends an email via Resend and logs it in
// public.notifications. Secrets live ONLY in Vercel env vars:
//   RESEND_API_KEY   (from resend.com)
//   RESEND_FROM      (verified sender, e.g. "Asset Track <ops@yourdomain.co.bw>")
//   SUPABASE_SERVICE_ROLE_KEY
//   CRON_SECRET      (for server-to-server calls, e.g. the daily digest)
//
// Callable by a signed-in staff member (Authorization: Bearer <access token>)
// or server-side with the cron secret. Any signed-in user may trigger a
// notification (e.g. assigning a task); we only send to the address given.

const SUPABASE_URL = "https://mdeotqkdjiylwtmtwtor.supabase.co";

function send(res, code, obj){
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(obj));
}
function esc(s){ return String(s == null ? "" : s).replace(/[&<>]/g, function(c){ return { "&":"&amp;", "<":"&lt;", ">":"&gt;" }[c]; }); }

// Minimal branded wrapper so every email looks consistent.
function wrap(title, lines){
  return '<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1a1a1a">'
    + '<div style="background:#c0202a;color:#fff;padding:16px 20px;border-radius:8px 8px 0 0;font-weight:700;font-size:16px">Asset Track</div>'
    + '<div style="border:1px solid #eee;border-top:none;border-radius:0 0 8px 8px;padding:20px">'
    + '<h2 style="margin:0 0 12px;font-size:18px">' + esc(title) + '</h2>'
    + lines.map(function(l){ return '<p style="margin:0 0 10px;line-height:1.5;font-size:14px">' + l + '</p>'; }).join('')
    + '<p style="margin:18px 0 0;color:#888;font-size:12px">Asset Track Back-Office · The Telematics Group</p>'
    + '</div></div>';
}

module.exports = async function handler(req, res){
  if(req.method !== "POST") return send(res, 405, { error: "Method not allowed" });

  const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const RESEND_KEY = process.env.RESEND_API_KEY;
  const FROM = process.env.RESEND_FROM;
  const CRON_SECRET = process.env.CRON_SECRET;
  if(!RESEND_KEY || !FROM) return send(res, 500, { error: "Add RESEND_API_KEY and RESEND_FROM in Vercel env vars." });
  if(!SERVICE_KEY) return send(res, 500, { error: "Add SUPABASE_SERVICE_ROLE_KEY in Vercel env vars." });

  // body
  let body = req.body;
  if(!body || typeof body === "string"){
    try { let raw=""; if(typeof body==="string"){ raw=body; } else { for await (const c of req){ raw+=c; } } body = raw ? JSON.parse(raw) : {}; }
    catch(e){ return send(res, 400, { error: "Invalid body" }); }
  }

  // authorize: cron secret or any signed-in user
  const auth = req.headers["authorization"] || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  let ok = CRON_SECRET && token === CRON_SECRET;
  if(!ok && token){
    const who = await fetch(SUPABASE_URL + "/auth/v1/user", { headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + token } });
    ok = who.ok;
  }
  if(!ok) return send(res, 401, { error: "Not authorized" });

  const to = String(body.to || "").trim();
  const subject = String(body.subject || "").trim();
  const title = String(body.title || subject).trim();
  const lines = Array.isArray(body.lines) ? body.lines.map(esc) : (body.html ? null : [esc(body.text || "")]);
  const html = body.html || wrap(title, lines || []);
  if(!to || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)){
    // Not a real address (e.g. internal @assettrack.local) — log as skipped, don't error.
    await logNote(SUPABASE_URL, SERVICE_KEY, "email", to, body.template, body, "skipped", body.related_task);
    return send(res, 200, { ok: true, skipped: true, reason: "no deliverable address" });
  }
  if(!subject) return send(res, 400, { error: "subject required" });

  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: "Bearer " + RESEND_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject: subject, html: html })
  });
  const data = await r.json().catch(function(){ return {}; });
  const status = r.ok ? "sent" : "failed";
  await logNote(SUPABASE_URL, SERVICE_KEY, "email", to, body.template, { subject: subject, resend: data }, status, body.related_task);
  if(!r.ok) return send(res, 502, { error: (data && data.message) || "Send failed", status: r.status });
  return send(res, 200, { ok: true, id: data.id });
};

async function logNote(url, key, channel, recipient, template, payload, status, relatedTask){
  try {
    await fetch(url + "/rest/v1/notifications", {
      method: "POST",
      headers: { apikey: key, Authorization: "Bearer " + key, "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify({ channel: channel, recipient: recipient || "—", template: template || null, payload: payload || null, status: status, related_task: relatedTask || null })
    });
  } catch(e){ /* logging is best-effort */ }
}
