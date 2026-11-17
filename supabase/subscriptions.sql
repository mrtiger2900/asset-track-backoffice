-- ============================================================================
-- Subscriptions + auto renewal tasks for Botshelo
-- ============================================================================

create table if not exists public.subscriptions (
  id          uuid primary key default gen_random_uuid(),
  reg         text not null,                 -- vehicle registration (ACTIVE ASSET)
  client_id   uuid references public.clients(id) on delete set null,
  client_name text,                          -- name as in the LocoNav export
  plan        text,
  expiry_date date not null,
  started_at  date,
  status      text not null default 'active',-- active | expired | cancelled
  source      text default 'loconav',
  created_at  timestamptz not null default now()
);
create index  if not exists idx_subs_expiry on public.subscriptions(expiry_date);
create unique index if not exists idx_subs_reg on public.subscriptions(reg);

alter table public.subscriptions enable row level security;
drop policy if exists subs_select on public.subscriptions;
create policy subs_select on public.subscriptions for select to authenticated using (true);
drop policy if exists subs_write on public.subscriptions;
create policy subs_write on public.subscriptions for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Tasks: category (keeps renewals out of the main board) + link back to the sub
alter table public.tasks add column if not exists category text not null default 'general';
alter table public.tasks add column if not exists subscription_id uuid references public.subscriptions(id) on delete set null;

-- Create a renewal task for Botshelo for each subscription entering the window.
-- Deduped per (subscription, expiry) so a renewal isn't duplicated and isn't
-- recreated once that expiry cycle has a task (open or done).
create or replace function public.generate_renewal_tasks()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  made int := 0; r record;
  today date := (now() at time zone 'Africa/Gaborone')::date;
  botshelo uuid;
  window_days int := 14;
begin
  select id into botshelo from public.profiles
    where lower(first_name)='botshelo' order by created_at limit 1;
  for r in
    select * from public.subscriptions
    where status='active' and expiry_date >= today and expiry_date <= today + (window_days || ' days')::interval
  loop
    if not exists (select 1 from public.tasks where subscription_id = r.id and due_date = r.expiry_date) then
      insert into public.tasks (title, client_id, all_clients, assigned_to, due_date, status, priority, recurrence, category, subscription_id, created_by)
      values ('Renew subscription — '||r.reg||coalesce(' ('||r.client_name||')',''),
              r.client_id, false, botshelo, r.expiry_date, 'open', 'high', 'none', 'subscription_renewal', r.id, botshelo);
      made := made + 1;
    end if;
  end loop;
  return made;
end;
$$;
grant execute on function public.generate_renewal_tasks() to authenticated, anon, service_role;

create extension if not exists pg_cron;
select cron.unschedule('generate-renewal-tasks') where exists (select 1 from cron.job where jobname='generate-renewal-tasks');
select cron.schedule('generate-renewal-tasks', '15 3 * * *', $$ select public.generate_renewal_tasks(); $$);
