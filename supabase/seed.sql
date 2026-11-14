-- ============================================================================
-- Asset Track Back-Office — Seed data (optional)
-- Reference data only: clients, vehicles, inventory, SIMs.
-- No user references, so it runs before any staff accounts exist.
-- Tasks, installations and comments are created in the app once users exist.
-- Safe to skip in production; useful for a first look.
-- ============================================================================

-- Clients -------------------------------------------------------------------
insert into public.clients (id, name, industry, contact_name, contact_phone, fleet_size, products, contract_expires) values
  ('11111111-0000-0000-0000-000000000001','Paper Group','Distribution','Gofaone Seretse','+267 71 234 567',14, array['GPS tracking','Dash cams'], '2027-03-01'),
  ('11111111-0000-0000-0000-000000000002','Trans Fridge Botswana','Cold chain','Louisa Bernard','+267 72 118 904',9, array['GPS tracking','Temp sensors'], '2026-12-15'),
  ('11111111-0000-0000-0000-000000000003','Sefalana Cash & Carry','Retail logistics','Oarabile Tau','+267 71 556 220',22, array['GPS tracking'], '2027-06-30'),
  ('11111111-0000-0000-0000-000000000004','Kalahari Haulage','Long-haul freight','Mpho Radipotsane','+267 73 902 441',18, array['GPS tracking','Diesel tracking'], '2026-11-28'),
  ('11111111-0000-0000-0000-000000000005','Choppies Distribution','Retail logistics','Neo Baleseng','+267 71 770 185',31, array['GPS tracking','Dash cams'], '2027-08-12')
on conflict (id) do nothing;

-- Vehicles ------------------------------------------------------------------
insert into public.vehicles (id, client_id, registration, make_model, tracker_serial) values
  ('22222222-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000005','B 418 CJQ','Hino 300','FMB920-004471'),
  ('22222222-0000-0000-0000-000000000002','11111111-0000-0000-0000-000000000003','B 902 DLR','Isuzu NPR','FMB920-009920'),
  ('22222222-0000-0000-0000-000000000003','11111111-0000-0000-0000-000000000004','B 771 AQP','Scania R500','FMB920-011185'),
  ('22222222-0000-0000-0000-000000000004','11111111-0000-0000-0000-000000000002','B 330 BRM','Isuzu FRR','FMB920-007733'),
  ('22222222-0000-0000-0000-000000000005','11111111-0000-0000-0000-000000000001','B 155 CKT','Toyota Hilux','FMB920-056602'),
  ('22222222-0000-0000-0000-000000000006','11111111-0000-0000-0000-000000000001','B 640 AFN','Toyota Hilux','FMB920-032208')
on conflict (registration) do nothing;

-- SIMs (as they would arrive from the 1oT sync) -----------------------------
insert into public.sims (iccid, msisdn, vehicle_id, client_id, network, state, last_seen, data_today_mb, data_month_mb) values
  ('89260113000000004471','+267 76 004 471','22222222-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000005','Orange','offline', now() - interval '31 hours', 0, 240),
  ('89260113000000009920','+267 76 009 920','22222222-0000-0000-0000-000000000002','11111111-0000-0000-0000-000000000003','Mascom','live', now() - interval '2 minutes', 41, 980),
  ('89260114000000001185','+267 76 011 185','22222222-0000-0000-0000-000000000003','11111111-0000-0000-0000-000000000004','Orange','live', now() - interval '1 minute', 58, 1320),
  ('89260112000000007733','+267 76 007 733','22222222-0000-0000-0000-000000000004','11111111-0000-0000-0000-000000000002','Mascom','live', now() - interval '4 minutes', 33, 710),
  ('89260115000000006602','+267 76 056 602','22222222-0000-0000-0000-000000000005','11111111-0000-0000-0000-000000000001','Orange','live', now() - interval '1 minute', 186, 2140),
  ('89260113000000002208','+267 76 032 208','22222222-0000-0000-0000-000000000006','11111111-0000-0000-0000-000000000001','Mascom','live', now() - interval '3 minutes', 29, 540)
on conflict (iccid) do nothing;

-- Inventory -----------------------------------------------------------------
insert into public.inventory_items (name, sku, category, in_stock, min_level, damaged) values
  ('Teltonika FMB920 GPS tracker','FMB920','tracker',12,10,1),
  ('Teltonika Eye Sensor (BLE temp)','EYE-T','sensor',7,8,0),
  ('Dash cam unit','DC-2','dash_cam',5,6,2),
  ('MicroSD card 128GB','SD-128','sd_card',8,15,3),
  ('Fuel level sensor','FLS-1','fuel_sensor',19,8,0),
  ('Wiring harness kit','WH-K','harness',24,10,0),
  ('SIM card (data)','SIM-D','sim',34,20,0),
  ('Insulation tape (roll)','CON-TAPE','consumable',40,20,0),
  ('Digital multimeter','TOOL-MM','consumable',3,3,1)
on conflict (sku) do nothing;

-- ============================================================================
-- Create your first admin after this runs:
--   1. Supabase dashboard -> Authentication -> Users -> Add user
--      (set email + password; add first_name / last_name / phone in metadata)
--   2. SQL:  update public.profiles
--            set role = 'admin',
--                module_access = array['dashboard','tasks','installs','clients','inventory','sims','reports','team']
--            where id = '<that user id>';
-- ============================================================================
