-- ============================================================================
-- Recurring tasks  (daily templates that auto-generate a fresh task each day)
-- Run PART 1 on its own first (enum values can't be added and used in the same
-- transaction), then run PART 2.
-- ============================================================================

-- ---- PART 1 : add 'daily' to the recurrence enum ---------------------------
alter type recurrence add value if not exists 'daily' before 'weekly';


-- ---- PART 2 : template table, generator, schedule --------------------------

-- Template: the definition of a repeating task. Instances live in public.tasks.
create table if not exists public.task_recurrences (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  client_id   uuid references public.clients(id) on delete set null,
  assigned_to uuid references public.profiles(id) on delete set null,
  priority    task_priority not null default 'medium',
  frequency   text not null default 'daily',   -- daily | weekly | monthly | quarterly
  note        text,
  active      boolean not null default true,
  created_by  uuid references public.profiles(id),
  created_at  timestamptz not null default now()
);

-- Link each generated task back to its template (so we can dedupe + stop it).
alter table public.tasks add column if not exists recurrence_id uuid
  references public.task_recurrences(id) on delete set null;
create index if not exists idx_tasks_recurrence on public.tasks(recurrence_id, due_date);

-- RLS: mirror the tasks table (any signed-in staff reads/creates; owner/admin edits).
alter table public.task_recurrences enable row level security;
drop policy if exists taskrec_select on public.task_recurrences;
create policy taskrec_select on public.task_recurrences for select to authenticated using (true);
drop policy if exists taskrec_insert on public.task_recurrences;
create policy taskrec_insert on public.task_recurrences for insert to authenticated with check (true);
drop policy if exists taskrec_update on public.task_recurrences;
create policy taskrec_update on public.task_recurrences for update to authenticated
  using (created_by = auth.uid() or public.is_admin())
  with check (created_by = auth.uid() or public.is_admin());
drop policy if exists taskrec_delete on public.task_recurrences;
create policy taskrec_delete on public.task_recurrences for delete to authenticated using (public.is_admin());

-- Generator: for every active template that is "due" today (Gaborone time),
-- create today's task if it doesn't already exist. Safe to run many times a day.
create or replace function public.generate_recurring_tasks()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  made    integer := 0;
  r       record;
  today   date := (now() at time zone 'Africa/Gaborone')::date;
  due_now boolean;
begin
  for r in select * from public.task_recurrences where active loop
    due_now := case r.frequency
      when 'daily'     then true
      when 'weekly'    then extract(dow  from today) = extract(dow  from (r.created_at at time zone 'Africa/Gaborone'))
      when 'monthly'   then extract(day  from today) = least(extract(day from (r.created_at at time zone 'Africa/Gaborone')),
                                                             extract(day from (date_trunc('month', today) + interval '1 month - 1 day')))
      when 'quarterly' then extract(day  from today) = extract(day from (r.created_at at time zone 'Africa/Gaborone'))
                            and (extract(month from today)::int % 3) = (extract(month from (r.created_at at time zone 'Africa/Gaborone'))::int % 3)
      else false
    end;

    if due_now and not exists (
      select 1 from public.tasks where recurrence_id = r.id and due_date = today
    ) then
      insert into public.tasks (title, client_id, assigned_to, due_date, status, priority, recurrence, recurrence_id, created_by)
      values (r.title, r.client_id, r.assigned_to, today, 'open', r.priority, r.frequency::recurrence, r.id, r.created_by);
      made := made + 1;
    end if;
  end loop;
  return made;
end;
$$;

grant execute on function public.generate_recurring_tasks() to authenticated, anon, service_role;

-- Schedule it every morning at 03:10 UTC (05:10 Gaborone), so the day's tasks
-- exist before anyone starts work. The login hook in the app is the backup.
create extension if not exists pg_cron;
select cron.unschedule('generate-recurring-tasks')
  where exists (select 1 from cron.job where jobname = 'generate-recurring-tasks');
select cron.schedule('generate-recurring-tasks', '10 3 * * *', $$ select public.generate_recurring_tasks(); $$);
