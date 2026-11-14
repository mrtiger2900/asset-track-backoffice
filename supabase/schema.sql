-- ============================================================================
-- Asset Track Back-Office — Database schema (PostgreSQL / Supabase)
-- Run this once in the Supabase SQL editor on a fresh project.
-- Idempotent where practical; safe to re-run.
-- ============================================================================

create extension if not exists "pgcrypto";
-- Allow functions to reference tables defined later in this same script.
set check_function_bodies = off;

-- ----------------------------------------------------------------------------
-- Enums
-- ----------------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type user_role as enum ('admin', 'technician');
  end if;
  if not exists (select 1 from pg_type where typname = 'task_status') then
    create type task_status as enum ('open', 'in_progress', 'done');
  end if;
  if not exists (select 1 from pg_type where typname = 'task_priority') then
    create type task_priority as enum ('low', 'medium', 'high', 'urgent');
  end if;
  if not exists (select 1 from pg_type where typname = 'recurrence') then
    create type recurrence as enum ('none', 'weekly', 'monthly', 'quarterly');
  end if;
  if not exists (select 1 from pg_type where typname = 'install_type') then
    create type install_type as enum ('new_install','dash_cam','temp_sensor','diesel_sensor','unit_swap','removal','maintenance');
  end if;
  if not exists (select 1 from pg_type where typname = 'install_status') then
    create type install_status as enum ('scheduled','in_progress','completed','cancelled');
  end if;
  if not exists (select 1 from pg_type where typname = 'sim_state') then
    -- mirrors 1oT Terminal API "state" field
    create type sim_state as enum ('live','test','live_ready','active_ready','offline','closed');
  end if;
  if not exists (select 1 from pg_type where typname = 'inventory_category') then
    create type inventory_category as enum ('tracker','sensor','dash_cam','sd_card','fuel_sensor','harness','sim','consumable','other');
  end if;
  if not exists (select 1 from pg_type where typname = 'movement_type') then
    create type movement_type as enum ('out','return','damage','restock');
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- Helper functions
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- SECURITY DEFINER so the check against profiles does not recurse through RLS.
create or replace function public.is_admin()
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- ----------------------------------------------------------------------------
-- profiles  (one row per auth user)
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  first_name    text not null default '',
  last_name     text not null default '',
  initials      text not null default 'U',
  role          user_role not null default 'technician',
  phone         text,                       -- E.164, used for WhatsApp notifications
  module_access text[] not null default array['dashboard','tasks','installs'],
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Auto-create a profile whenever a user signs up / is invited.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.profiles (id, first_name, last_name, initials, role, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'first_name',''),
    coalesce(new.raw_user_meta_data->>'last_name',''),
    upper(left(coalesce(new.raw_user_meta_data->>'first_name','U'),1) ||
          left(coalesce(new.raw_user_meta_data->>'last_name',''),1)),
    'technician',
    new.raw_user_meta_data->>'phone'
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- clients
-- ----------------------------------------------------------------------------
create table if not exists public.clients (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  industry         text,
  contact_name     text,
  contact_phone    text,
  fleet_size       integer not null default 0,
  products         text[] not null default array[]::text[],
  country          text not null default 'Botswana',
  contract_expires date,
  created_by       uuid references public.profiles(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- vehicles  (target of the weekly CSV import; links a client to its units)
-- ----------------------------------------------------------------------------
create table if not exists public.vehicles (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid references public.clients(id) on delete set null,
  registration   text not null unique,
  make_model     text,
  tracker_serial text,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- sims  (synced from the 1oT Terminal API)
-- ----------------------------------------------------------------------------
create table if not exists public.sims (
  id             uuid primary key default gen_random_uuid(),
  iccid          text not null unique,
  msisdn         text,
  vehicle_id     uuid references public.vehicles(id) on delete set null,
  client_id      uuid references public.clients(id) on delete set null,
  network        text,
  state          sim_state not null default 'live',
  last_seen      timestamptz,
  data_today_mb  numeric(12,2) not null default 0,
  data_month_mb  numeric(12,2) not null default 0,
  synced_at      timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- tasks
-- ----------------------------------------------------------------------------
create table if not exists public.tasks (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  client_id    uuid references public.clients(id) on delete set null,
  vehicle_id   uuid references public.vehicles(id) on delete set null,
  assigned_to  uuid references public.profiles(id) on delete set null,
  status       task_status not null default 'open',
  priority     task_priority not null default 'medium',
  recurrence   recurrence not null default 'none',
  due_date     date,
  created_by   uuid references public.profiles(id),
  completed_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.task_comments (
  id         uuid primary key default gen_random_uuid(),
  task_id    uuid not null references public.tasks(id) on delete cascade,
  author_id  uuid references public.profiles(id) on delete set null,
  body       text not null,
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- installations
-- ----------------------------------------------------------------------------
create table if not exists public.installations (
  id             uuid primary key default gen_random_uuid(),
  ref            text not null unique,
  client_id      uuid references public.clients(id) on delete set null,
  vehicle_id     uuid references public.vehicles(id) on delete set null,
  contact_name   text,
  contact_phone  text,
  vehicle_reg    text,
  job_type       install_type not null default 'new_install',
  scheduled_date date,
  scheduled_time time,
  location       text,
  assigned_to    uuid references public.profiles(id) on delete set null,
  status         install_status not null default 'scheduled',
  signed         boolean not null default false,
  signed_at      timestamptz,
  signature_path text,                       -- storage path of the signature image
  created_by     uuid references public.profiles(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table if not exists public.installation_photos (
  id              uuid primary key default gen_random_uuid(),
  installation_id uuid not null references public.installations(id) on delete cascade,
  storage_path    text not null,
  uploaded_by     uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- inventory
-- ----------------------------------------------------------------------------
create table if not exists public.inventory_items (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  sku        text unique,
  category   inventory_category not null default 'other',
  in_stock   integer not null default 0,
  min_level  integer not null default 0,
  damaged    integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Immutable ledger of every stock movement (who took what, for which client).
create table if not exists public.stock_movements (
  id            uuid primary key default gen_random_uuid(),
  item_id       uuid not null references public.inventory_items(id) on delete cascade,
  movement_type movement_type not null,
  quantity      integer not null check (quantity > 0),
  client_id     uuid references public.clients(id) on delete set null,
  performed_by  uuid references public.profiles(id) on delete set null,
  purpose       text,
  note          text,
  created_at    timestamptz not null default now()
);

-- Keep inventory counts in step with the ledger automatically.
create or replace function public.apply_stock_movement()
returns trigger language plpgsql as $$
begin
  if new.movement_type = 'out' then
    update public.inventory_items set in_stock = in_stock - new.quantity, updated_at = now() where id = new.item_id;
  elsif new.movement_type = 'restock' or new.movement_type = 'return' then
    update public.inventory_items set in_stock = in_stock + new.quantity, updated_at = now() where id = new.item_id;
  elsif new.movement_type = 'damage' then
    update public.inventory_items set in_stock = in_stock - new.quantity, damaged = damaged + new.quantity, updated_at = now() where id = new.item_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_apply_stock_movement on public.stock_movements;
create trigger trg_apply_stock_movement
  after insert on public.stock_movements
  for each row execute function public.apply_stock_movement();

-- ----------------------------------------------------------------------------
-- notifications  (log of WhatsApp / email sent — the WhatsApp-first channel)
-- ----------------------------------------------------------------------------
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  channel    text not null default 'whatsapp',   -- whatsapp | email
  recipient  text not null,                       -- phone or email
  template   text,                                -- e.g. task_assigned, task_due, install_scheduled
  payload    jsonb,
  status     text not null default 'queued',      -- queued | sent | failed
  related_task uuid references public.tasks(id) on delete set null,
  related_install uuid references public.installations(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Log of weekly vehicle CSV imports.
create table if not exists public.csv_imports (
  id          uuid primary key default gen_random_uuid(),
  filename    text,
  rows_total  integer,
  rows_added  integer,
  rows_updated integer,
  imported_by uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- updated_at triggers
-- ----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles','clients','vehicles','sims','tasks','installations','inventory_items']
  loop
    execute format('drop trigger if exists trg_updated_at on public.%I;', t);
    execute format('create trigger trg_updated_at before update on public.%I for each row execute function public.set_updated_at();', t);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- Indexes
-- ----------------------------------------------------------------------------
create index if not exists idx_vehicles_client   on public.vehicles(client_id);
create index if not exists idx_sims_vehicle       on public.sims(vehicle_id);
create index if not exists idx_sims_state         on public.sims(state);
create index if not exists idx_tasks_assigned     on public.tasks(assigned_to);
create index if not exists idx_tasks_status       on public.tasks(status);
create index if not exists idx_tasks_due          on public.tasks(due_date);
create index if not exists idx_comments_task      on public.task_comments(task_id);
create index if not exists idx_installs_status    on public.installations(status);
create index if not exists idx_installs_assigned  on public.installations(assigned_to);
create index if not exists idx_movements_item     on public.stock_movements(item_id);

-- ----------------------------------------------------------------------------
-- Row-Level Security
-- Starting policy set for an internal tool: every signed-in staff member can
-- read; writes are gated by role or ownership. Tighten per module as needed.
-- ----------------------------------------------------------------------------
alter table public.profiles            enable row level security;
alter table public.clients             enable row level security;
alter table public.vehicles            enable row level security;
alter table public.sims                enable row level security;
alter table public.tasks               enable row level security;
alter table public.task_comments       enable row level security;
alter table public.installations       enable row level security;
alter table public.installation_photos enable row level security;
alter table public.inventory_items     enable row level security;
alter table public.stock_movements     enable row level security;
alter table public.notifications       enable row level security;
alter table public.csv_imports         enable row level security;

-- profiles
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (true);
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());
drop policy if exists profiles_admin_write on public.profiles;
create policy profiles_admin_write on public.profiles for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- clients  (field staff may add; only admins edit/remove master data)
drop policy if exists clients_select on public.clients;
create policy clients_select on public.clients for select to authenticated using (true);
drop policy if exists clients_insert on public.clients;
create policy clients_insert on public.clients for insert to authenticated with check (true);
drop policy if exists clients_update on public.clients;
create policy clients_update on public.clients for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists clients_delete on public.clients;
create policy clients_delete on public.clients for delete to authenticated using (public.is_admin());

-- vehicles
drop policy if exists vehicles_select on public.vehicles;
create policy vehicles_select on public.vehicles for select to authenticated using (true);
drop policy if exists vehicles_write on public.vehicles;
create policy vehicles_write on public.vehicles for insert to authenticated with check (true);
drop policy if exists vehicles_update on public.vehicles;
create policy vehicles_update on public.vehicles for update to authenticated using (true) with check (true);
drop policy if exists vehicles_delete on public.vehicles;
create policy vehicles_delete on public.vehicles for delete to authenticated using (public.is_admin());

-- sims  (read for all; writes by admin or the sync job using the service role,
--        which bypasses RLS entirely)
drop policy if exists sims_select on public.sims;
create policy sims_select on public.sims for select to authenticated using (true);
drop policy if exists sims_write on public.sims;
create policy sims_write on public.sims for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- tasks
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select to authenticated using (true);
drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert to authenticated with check (true);
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks for update to authenticated
  using (public.is_admin() or assigned_to = auth.uid() or created_by = auth.uid())
  with check (public.is_admin() or assigned_to = auth.uid() or created_by = auth.uid());
drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks for delete to authenticated using (public.is_admin());

-- task_comments
drop policy if exists comments_select on public.task_comments;
create policy comments_select on public.task_comments for select to authenticated using (true);
drop policy if exists comments_insert on public.task_comments;
create policy comments_insert on public.task_comments for insert to authenticated with check (author_id = auth.uid());
drop policy if exists comments_modify on public.task_comments;
create policy comments_modify on public.task_comments for all to authenticated using (author_id = auth.uid() or public.is_admin()) with check (author_id = auth.uid() or public.is_admin());

-- installations
drop policy if exists installs_select on public.installations;
create policy installs_select on public.installations for select to authenticated using (true);
drop policy if exists installs_insert on public.installations;
create policy installs_insert on public.installations for insert to authenticated with check (true);
drop policy if exists installs_update on public.installations;
create policy installs_update on public.installations for update to authenticated
  using (public.is_admin() or assigned_to = auth.uid())
  with check (public.is_admin() or assigned_to = auth.uid());
drop policy if exists installs_delete on public.installations;
create policy installs_delete on public.installations for delete to authenticated using (public.is_admin());

-- installation_photos
drop policy if exists photos_select on public.installation_photos;
create policy photos_select on public.installation_photos for select to authenticated using (true);
drop policy if exists photos_insert on public.installation_photos;
create policy photos_insert on public.installation_photos for insert to authenticated with check (true);
drop policy if exists photos_delete on public.installation_photos;
create policy photos_delete on public.installation_photos for delete to authenticated using (uploaded_by = auth.uid() or public.is_admin());

-- inventory_items
drop policy if exists inventory_select on public.inventory_items;
create policy inventory_select on public.inventory_items for select to authenticated using (true);
drop policy if exists inventory_insert on public.inventory_items;
create policy inventory_insert on public.inventory_items for insert to authenticated with check (public.is_admin());
drop policy if exists inventory_update on public.inventory_items;
create policy inventory_update on public.inventory_items for update to authenticated using (true) with check (true);
drop policy if exists inventory_delete on public.inventory_items;
create policy inventory_delete on public.inventory_items for delete to authenticated using (public.is_admin());

-- stock_movements  (append-only ledger)
drop policy if exists movements_select on public.stock_movements;
create policy movements_select on public.stock_movements for select to authenticated using (true);
drop policy if exists movements_insert on public.stock_movements;
create policy movements_insert on public.stock_movements for insert to authenticated with check (performed_by = auth.uid());
drop policy if exists movements_delete on public.stock_movements;
create policy movements_delete on public.stock_movements for delete to authenticated using (public.is_admin());

-- notifications & csv_imports
drop policy if exists notifications_rw on public.notifications;
create policy notifications_rw on public.notifications for all to authenticated using (true) with check (true);
drop policy if exists imports_rw on public.csv_imports;
create policy imports_rw on public.csv_imports for all to authenticated using (true) with check (true);

-- ----------------------------------------------------------------------------
-- Storage buckets (installation photos & signatures)
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('installation-media', 'installation-media', false)
on conflict (id) do nothing;

drop policy if exists install_media_read on storage.objects;
create policy install_media_read on storage.objects for select to authenticated
  using (bucket_id = 'installation-media');
drop policy if exists install_media_write on storage.objects;
create policy install_media_write on storage.objects for insert to authenticated
  with check (bucket_id = 'installation-media');

-- ============================================================================
-- End of schema
-- ============================================================================
