alter table public.tasks            add column if not exists all_clients boolean not null default false;
alter table public.task_recurrences add column if not exists all_clients boolean not null default false;

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
      insert into public.tasks (title, client_id, all_clients, assigned_to, due_date, status, priority, recurrence, recurrence_id, created_by)
      values (r.title, r.client_id, r.all_clients, r.assigned_to, today, 'open', r.priority, r.frequency::recurrence, r.id, r.created_by);
      made := made + 1;
    end if;
  end loop;
  return made;
end;
$$;
