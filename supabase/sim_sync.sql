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

-- Task generator: one INSERT…SELECT that raises a task for every offline SIM
-- that is linked to a client and has no open task yet. Linked-only keeps it
-- meaningful and prevents a flood (a telematics SIM pool has many spare/idle
-- SIMs). Unlinked offline SIMs are still visible on the SIM page.
create or replace function public.generate_sim_offline_tasks()
returns integer language plpgsql security definer set search_path=public as $$
declare made integer;
begin
  with ins as (
    insert into public.tasks (title, client_id, due_date, status, priority, recurrence, category, sim_iccid)
    select 'Offline tracker — '||coalesce(nullif(s.sim_name,''), s.iccid)||' (no data 12h+)',
           s.client_id, (now() at time zone 'Africa/Gaborone')::date,
           'open','urgent','none','sim_offline', s.iccid
    from public.sims s
    where s.state='offline' and s.client_id is not null
      and not exists (select 1 from public.tasks t where t.sim_iccid=s.iccid and t.status<>'done')
    returning 1
  ) select count(*) into made from ins;
  return made;
end; $$;

grant execute on function public.generate_sim_offline_tasks() to authenticated, anon, service_role;
