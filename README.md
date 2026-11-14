# Asset Track Back-Office

Internal operations and CRM platform for **Asset Track** (The Telematics Group Pty Ltd) —
task management, installations, clients, vehicles, inventory and SIM monitoring for a
growing telematics business. Built to run on a static front-end + Supabase (Postgres)
backend, deployed on Vercel.

> Status: front-end prototype + full database schema. The UI currently runs on an
> in-browser demo store; the next step is wiring it to Supabase (see **Roadmap**).

---

## Stack

| Layer      | Choice                                            |
|------------|---------------------------------------------------|
| Front-end  | Static HTML/CSS/JS (no build step), hosted on Vercel |
| Database   | Supabase (PostgreSQL) with Row-Level Security     |
| Auth       | Supabase Auth (email + password)                  |
| Storage    | Supabase Storage (`installation-media` bucket)    |
| SIM data   | 1oT Terminal API → scheduled sync into `sims`     |
| Messaging  | WhatsApp Business API (task & install notifications) |

## Repository layout

```
asset-track-backoffice/
├── public/                  # the deployed site (Vercel outputDirectory)
│   ├── index.html           # the back-office app
│   └── js/
│       ├── config.example.js  # copy to config.js, fill in Supabase keys
│       └── supabaseClient.js  # Supabase client + data-access layer
├── supabase/
│   ├── schema.sql           # full database: tables, enums, triggers, RLS, storage
│   └── seed.sql             # optional reference data (clients, vehicles, inventory, SIMs)
├── .env.example             # server-side keys (SIM sync, WhatsApp) — never commit real values
├── vercel.json
└── README.md
```

## Setup

### 1. Database
1. Create a project at [supabase.com](https://supabase.com).
2. In the SQL editor, run **`supabase/schema.sql`**.
3. (Optional) run **`supabase/seed.sql`** for demo reference data.
4. Create your first admin: Authentication → Users → Add user, then run the
   `update public.profiles …` snippet at the bottom of `seed.sql` with that user's id.

### 2. Front-end config
```bash
cp public/js/config.example.js public/js/config.js
# edit public/js/config.js with your Project URL + anon key (Settings → API)
```

### 3. Run locally
Serve the `public/` folder over HTTP (not file://, so auth works):
```bash
npx serve public      # or: python3 -m http.server --directory public 8000
```

### 4. Deploy
Push to GitHub and import the repo in Vercel. Set the output directory to `public`.
Add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as Vercel env vars (or ship `config.js`).

## Database overview

- **profiles** — staff accounts (admin / technician), per-module access, WhatsApp phone. Auto-created on sign-up.
- **clients** — client record, contacts, fleet size, products held, contract expiry.
- **vehicles** — one row per tracked vehicle; the weekly CSV import target. Linked to a client.
- **sims** — SIM inventory + live state/usage, synced from the 1oT Terminal API.
- **tasks** / **task_comments** — recurring & one-off work, assignment, hand-off, findings.
- **installations** / **installation_photos** — job cards, schedule, photos, client sign-off.
- **inventory_items** / **stock_movements** — stock on hand + an append-only ledger (who took what, for which client); a trigger keeps counts and damages in step.
- **notifications** — log of WhatsApp/email sent. **csv_imports** — weekly vehicle import log.

Row-Level Security is on for every table: all staff can read; writes are gated by
role (`is_admin()`) or ownership. The policies in `schema.sql` are a sensible starting
set — tighten per module as the team grows.

## Integrations (planned)

- **1oT Terminal API** (`https://api.1ot.mobi/v1`) — a scheduled job authenticates via
  `/oauth/token`, pulls `/get_account_sims` + `/get_daily_usage`, upserts into `sims`,
  and auto-creates a task when a SIM goes `offline`. Uses the service-role key, server-side only.
- **WhatsApp** — on task assigned / due and install scheduled, send the technician a
  templated WhatsApp (via Twilio or 360dialog). Logged in `notifications`.
- **Weekly vehicle CSV** — every Monday, import the current vehicle list; match on
  `registration`, add new vehicles, link to clients, log the run in `csv_imports`.

## Roadmap

- [x] Front-end prototype (all modules, demo data)
- [x] Full Postgres schema + RLS + storage
- [ ] Wire the UI to Supabase (auth + the in-memory cache in `supabaseClient.js`)
- [ ] 1oT SIM sync job
- [ ] WhatsApp notifications
- [ ] Weekly CSV import
- [ ] Vehicles module (work history per vehicle)
