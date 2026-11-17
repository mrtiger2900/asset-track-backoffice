// Supabase client + data-access layer for Asset Track Back-Office.
// Loads after the Supabase UMD build (see index.html) and after config.js.
//
// This is the bridge between the UI and the database. The UI loads all
// working data into memory on sign-in (the dataset is small — a few hundred
// rows), renders from that cache, and every write goes to Supabase AND updates
// the cache so the screen stays responsive.

(function () {
  "use strict";
  var cfg = window.ASSET_TRACK_CONFIG || {};
  if (!cfg.SUPABASE_URL || !cfg.SUPABASE_ANON_KEY) {
    console.error("Missing Supabase config. Copy js/config.example.js to js/config.js and fill it in.");
  }
  // supabase global comes from the UMD script in index.html
  var client = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);

  var API = {
    client: client,

    // ---- Auth -------------------------------------------------------------
    async signIn(email, password) {
      return client.auth.signInWithPassword({ email: email, password: password });
    },
    async signOut() { return client.auth.signOut(); },
    async currentSession() { return client.auth.getSession(); },
    async myProfile() {
      var u = (await client.auth.getUser()).data.user;
      if (!u) return null;
      var r = await client.from("profiles").select("*").eq("id", u.id).single();
      return r.data;
    },

    // ---- Bulk load (called once on sign-in) -------------------------------
    async loadAll() {
      var tables = ["profiles", "clients", "vehicles", "sims", "tasks",
                    "task_comments", "installations", "inventory_items", "stock_movements",
                    "subscriptions", "task_recurrences"];
      var out = {};
      await Promise.all(tables.map(async function (t) {
        var r = await client.from(t).select("*");
        out[t] = r.error ? [] : r.data;
      }));
      return out;
    },

    // ---- Recurring tasks --------------------------------------------------
    async createRecurrence(t)      { return client.from("task_recurrences").insert(t).select().single(); },
    async stopRecurrence(id)       { return client.from("task_recurrences").update({ active:false }).eq("id", id); },
    async generateDaily()          { return client.rpc("generate_recurring_tasks"); },
    async generateRenewals()       { return client.rpc("generate_renewal_tasks"); },

    // ---- Tasks ------------------------------------------------------------
    async createTask(t)            { return client.from("tasks").insert(t).select().single(); },
    async updateTask(id, patch)    { return client.from("tasks").update(patch).eq("id", id).select().single(); },
    async reassignTask(id, userId) { return client.from("tasks").update({ assigned_to: userId }).eq("id", id); },
    async deleteTask(id)           { return client.from("tasks").delete().eq("id", id); },
    async addComment(c)            { return client.from("task_comments").insert(c).select().single(); },

    // ---- Installations ----------------------------------------------------
    async createInstall(i)         { return client.from("installations").insert(i).select().single(); },
    async updateInstall(id, patch) { return client.from("installations").update(patch).eq("id", id).select().single(); },

    // ---- Clients & vehicles ----------------------------------------------
    async createClient(c)          { return client.from("clients").insert(c).select().single(); },
    async upsertVehicles(rows)     { return client.from("vehicles").upsert(rows, { onConflict: "registration" }); },

    // ---- Inventory --------------------------------------------------------
    async createItem(it)           { return client.from("inventory_items").insert(it).select().single(); },
    async moveStock(m)             { return client.from("stock_movements").insert(m).select().single(); }, // trigger adjusts counts

    // ---- Team -------------------------------------------------------------
    async updateProfile(id, patch) { return client.from("profiles").update(patch).eq("id", id).select().single(); },
    async createUser(payload) {
      var sess = (await client.auth.getSession()).data.session;
      var token = sess && sess.access_token;
      var res = await fetch("/api/create-user", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + (token || "") },
        body: JSON.stringify(payload)
      });
      var data = await res.json().catch(function(){ return {}; });
      if (!res.ok) return { error: { message: (data && data.error) || ("Request failed (" + res.status + ")") } };
      return { data: data };
    },

    // ---- SIMs (the 1oT sync target) --------------------------------------
    async upsertSims(rows)         { return client.from("sims").upsert(rows, { onConflict: "iccid" }); }
  };

  window.AssetTrackAPI = API;
})();
