-- ============================================================================
-- 1oT SIM sync  (live connectivity + "no data session in 12h" alerts)
-- Safe to run more than once.
-- ============================================================================

-- Extra connectivity columns the 1oT sync writes into the sims table.
alter table public.sims add column if not exists last_data_session       timestamptz;
alter table public.sims add column if not exists last_network_activity   timestamptz;
alter table public.sims add column if not exists data_used_mb            numeric(14,2) not null default 0;
alter table public.sims add column if not exists last_country            text;
alter table public.sims add column if not exists sim_name               text;
alter table public.sims add column if not exists offline_since           timestamptz;  -- when we first saw it go quiet

-- Let the sync upsert SIMs by iccid (merge-duplicates needs the unique key,
-- which already exists as sims.iccid unique — no change needed).

-- Tag tasks that were auto-raised for a quiet SIM, so we never raise a second
-- open one for the same SIM.
alter table public.tasks add column if not exists sim_iccid text;
create index if not exists idx_tasks_sim_iccid on public.tasks(sim_iccid) where sim_iccid is not null;

-- Category value used for these tasks is 'sim_offline' (tasks.category already
-- exists from the subscriptions migration). No enum change required — category
-- is free text.
