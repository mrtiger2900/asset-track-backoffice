// Asset Track Back-Office — secure server-side user creation.
//
// Runs as a Vercel serverless function (Node 18+, global fetch). It is the ONLY
// place the Supabase service_role key is used, and that key lives solely in the
// Vercel environment variable SUPABASE_SERVICE_ROLE_KEY — never in the browser,
// never in git. The browser calls this endpoint with the signed-in admin's
// access token; we verify that caller really is an admin before creating anyone.

const SUPABASE_URL = "https://mdeotqkdjiylwtmtwtor.supabase.co";
const EMAIL_DOMAIN = "assettrack.local";
const VALID_MODULES = ["dashboard","tasks","installs","clients","vehicles","inventory","sims","reports","team"];

function send(res, code, obj){
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(obj));
}

module.exports = async function handler(req, res){
  if(req.method !== "POST") return send(res, 405, { error: "Method not allowed" });

  const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if(!SERVICE_KEY){
    return send(res, 500, { error: "Server not configured. Add SUPABASE_SERVICE_ROLE_KEY in Vercel → Settings → Environment Variables, then redeploy." });
  }

  // --- read body (Vercel usually parses JSON; fall back to manual) ---
  let body = req.body;
  if(!body || typeof body === "string"){
    try {
      let raw = "";
      if(typeof body === "string"){ raw = body; }
      else { for await (const chunk of req){ raw += chunk; } }
      body = raw ? JSON.parse(raw) : {};
    } catch(e){ return send(res, 400, { error: "Invalid request body" }); }
  }

  // --- authenticate the caller ---
  const auth = req.headers["authorization"] || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if(!token) return send(res, 401, { error: "Not signed in" });

  const whoRes = await fetch(SUPABASE_URL + "/auth/v1/user", {
    headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + token }
  });
  if(!whoRes.ok) return send(res, 401, { error: "Session expired. Sign out and in again." });
  const caller = await whoRes.json();

  const profRes = await fetch(SUPABASE_URL + "/rest/v1/profiles?id=eq." + caller.id + "&select=role", {
    headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY }
  });
  const profArr = profRes.ok ? await profRes.json() : [];
  if(!profArr[0] || profArr[0].role !== "admin"){
    return send(res, 403, { error: "Only admins can create users." });
  }

  // --- validate input ---
  const username = String(body.username || "").trim().toLowerCase().replace(/\s+/g, "");
  const password = String(body.password || "");
  const first_name = String(body.first_name || "").trim();
  const last_name = String(body.last_name || "").trim();
  const role = body.role === "admin" ? "admin" : "technician";
  const phone = String(body.phone || "").trim() || null;
  let module_access = Array.isArray(body.module_access) ? body.module_access.filter(m => VALID_MODULES.includes(m)) : [];
  if(role === "admin") module_access = VALID_MODULES.slice();
  if(module_access.indexOf("dashboard") < 0) module_access.unshift("dashboard");

  if(!username || !/^[a-z0-9._-]+$/.test(username)) return send(res, 400, { error: "Username can use letters, numbers, dot, dash, underscore." });
  if(password.length < 6) return send(res, 400, { error: "Password must be at least 6 characters." });
  if(!first_name) return send(res, 400, { error: "First name is required." });

  const email = username.indexOf("@") >= 0 ? username : (username + "@" + EMAIL_DOMAIN);
  const initials = ((first_name[0] || "") + (last_name[0] || "")).toUpperCase() || "U";

  // --- create the auth user (email pre-confirmed; internal domain gets no mail) ---
  const createRes = await fetch(SUPABASE_URL + "/auth/v1/admin/users", {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password, email_confirm: true })
  });
  const created = await createRes.json();
  if(!createRes.ok){
    const msg = (created && (created.msg || created.message || created.error_description)) || "Could not create user.";
    const code = /already|registered|exists/i.test(msg) ? 409 : 400;
    return send(res, code, { error: code === 409 ? "That username is already taken." : msg });
  }
  const newId = created.id || (created.user && created.user.id);
  if(!newId) return send(res, 500, { error: "User created but no id returned." });

  // --- set the profile fields (a trigger already created the row) ---
  const patchRes = await fetch(SUPABASE_URL + "/rest/v1/profiles?id=eq." + newId, {
    method: "PATCH",
    headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY, "Content-Type": "application/json", Prefer: "return=representation" },
    body: JSON.stringify({ first_name, last_name, initials, role, module_access, phone })
  });
  if(!patchRes.ok){
    const t = await patchRes.text();
    return send(res, 500, { error: "User login created, but saving their profile failed: " + t });
  }

  return send(res, 200, { ok: true, id: newId, username });
};
