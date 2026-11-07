-- =====================================================================
-- BlueBay database, part 5: you have to be there
-- Run once in the Supabase SQL Editor, after parts 1 to 4.
--
-- The app sends the phone's GPS position with each action, and the
-- database refuses it if the person is too far from the bay:
--   capture a bay           within 100 m
--   report Free / Taken     within 150 m
--   add a new bay           within 100 m of where they place it
-- A little slack is added for GPS accuracy (up to 50 m extra).
-- Releasing a bay works from anywhere. OpenStreetMap imports are not checked.
-- =====================================================================

-- Distance in metres between two points
create or replace function public.distance_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns float8 language sql immutable set search_path = '' as $$
  select 12742000 * asin(sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2)
         + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

-- Where the person was when they did it (also handy for spotting cheaters later)
alter table public.reports  add column from_lat float8, add column from_lng float8, add column from_acc real;
alter table public.captures add column from_lat float8, add column from_lng float8, add column from_acc real;
alter table public.bays     add column from_lat float8, add column from_lng float8, add column from_acc real;

grant insert (from_lat, from_lng, from_acc) on public.reports, public.captures, public.bays to authenticated;

-- The check. Only applies to app users (the "authenticated" role), so the
-- automatic reports made when capturing/releasing, and the SQL Editor, skip it.
create or replace function public.check_nearby() returns trigger
language plpgsql set search_path = '' as $$
declare
  lim  float8 := tg_argv[0]::float8;
  blat float8; blng float8; d float8;
begin
  if current_user <> 'authenticated' then return new; end if;
  if tg_table_name = 'bays' then
    if new.source = 'osm' then return new; end if;
    blat := new.lat; blng := new.lng;
  else
    select b.lat, b.lng into blat, blng from public.bays b where b.id = new.bay_id;
  end if;
  if new.from_lat is null or new.from_lng is null then
    raise exception 'location_required' using errcode = 'P0001';
  end if;
  d := public.distance_m(new.from_lat, new.from_lng, blat, blng);
  if d > lim + least(greatest(coalesce(new.from_acc, 0), 0), 50) then
    raise exception 'too_far:%', round(d) using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger captures_nearby before insert on public.captures
  for each row execute function public.check_nearby('100');
create trigger reports_nearby before insert on public.reports
  for each row execute function public.check_nearby('150');
create trigger bays_nearby before insert on public.bays
  for each row execute function public.check_nearby('100');
