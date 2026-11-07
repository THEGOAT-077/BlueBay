-- =====================================================================
-- BlueBay database, part 1 of 2: bays, reports and captures
-- Run once in the Supabase SQL Editor on a fresh project, then run part 2.
--
--   bays       every accessible parking bay (from OpenStreetMap or added by a user)
--   reports    "free" / "taken" ticks from the community
--   captures   who is parked in a bay; open while ended_at is null (taken),
--              closed when the driver releases it (released)
--   bay_status one row per bay with its current status (part 2 replaces it
--              with a fuller version that adds votes and names)
--
-- Status rule: an open capture always means "taken". Otherwise the latest
-- report from the last 20 minutes wins. With no recent report it's "unk".
-- =====================================================================

-- ---------- bays ----------
create table public.bays (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default 'Accessible bay'
              check (char_length(btrim(name)) between 1 and 80),
  lat         double precision not null check (lat between -90 and 90),
  lng         double precision not null check (lng between -180 and 180),
  source      text not null default 'user' check (source in ('osm', 'user')),
  osm_ref     text unique,                      -- e.g. 'node/123456' for OpenStreetMap bays
  created_by  uuid default auth.uid() references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  check ((source = 'osm') = (osm_ref is not null))
);
alter table public.bays enable row level security;

-- ---------- reports ----------
create table public.reports (
  id          bigint generated always as identity primary key,
  bay_id      uuid not null references public.bays (id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  status      text not null check (status in ('free', 'taken')),
  created_at  timestamptz not null default now()
);
alter table public.reports enable row level security;
create index reports_bay_time on public.reports (bay_id, created_at desc);

-- ---------- captures ----------
create table public.captures (
  id          bigint generated always as identity primary key,
  bay_id      uuid not null references public.bays (id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  check (ended_at is null or ended_at >= started_at)
);
alter table public.captures enable row level security;
-- Only one person can hold a bay, and each person can hold only one bay.
create unique index captures_one_open_per_bay  on public.captures (bay_id)  where ended_at is null;
create unique index captures_one_open_per_user on public.captures (user_id) where ended_at is null;
create index captures_bay on public.captures (bay_id);

-- ---------- What each role may touch ----------
-- Supabase gives anon/authenticated full table rights by default; take them
-- back and hand out only what the app needs. Columns not listed (ids,
-- user_id, timestamps) are filled by the database, so nobody can fake them.
revoke all on public.bays, public.reports, public.captures from anon, authenticated;
grant select on public.bays, public.reports, public.captures to anon, authenticated;
grant insert (name, lat, lng, source, osm_ref) on public.bays     to authenticated;
grant insert (bay_id, status)                  on public.reports  to authenticated;
grant insert (bay_id)                          on public.captures to authenticated;
grant update (ended_at)                        on public.captures to authenticated;

-- ---------- Security rules (row level security) ----------
-- Anonymous sign-in users have the "authenticated" role too.
create policy "Anyone can read bays"      on public.bays     for select to anon, authenticated using (true);
create policy "Anyone can read reports"   on public.reports  for select to anon, authenticated using (true);
create policy "Anyone can read captures"  on public.captures for select to anon, authenticated using (true);

create policy "Signed-in users add bays as themselves"
  on public.bays for insert to authenticated
  with check (created_by = auth.uid());

create policy "Signed-in users report as themselves"
  on public.reports for insert to authenticated
  with check (user_id = auth.uid());

create policy "Signed-in users capture as themselves"
  on public.captures for insert to authenticated
  with check (user_id = auth.uid());

create policy "Users release only their own open capture"
  on public.captures for update to authenticated
  using (user_id = auth.uid() and ended_at is null)
  with check (user_id = auth.uid() and ended_at is not null);

-- ---------- Release time is always "now" ----------
create function public.captures_stamp_release() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.ended_at := now();
  return new;
end $$;

create trigger captures_stamp_release
  before update on public.captures
  for each row execute function public.captures_stamp_release();

-- ---------- Capturing / releasing also counts as a report ----------
-- Capture -> "taken" report. Release -> "free" report. This keeps the
-- history in one place and makes a released bay show as free right away.
create function public.captures_to_reports() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.reports (bay_id, user_id, status) values (new.bay_id, new.user_id, 'taken');
  elsif old.ended_at is null and new.ended_at is not null then
    insert into public.reports (bay_id, user_id, status) values (new.bay_id, new.user_id, 'free');
  end if;
  return null;
end $$;

create trigger captures_to_reports
  after insert or update on public.captures
  for each row execute function public.captures_to_reports();

-- ---------- Current status of every bay ----------
create view public.bay_status with (security_invoker = true) as
select
  b.id, b.name, b.lat, b.lng, b.source, b.osm_ref, b.created_by,
  case when c.id is not null then 'taken' else coalesce(r.status, 'unk') end as status,
  case when c.id is not null then c.started_at else r.created_at end         as status_at,
  case when c.id is not null then 1 else coalesce(r.confirmations, 0) end   as confirmations,
  (select max(x.created_at) from public.reports x where x.bay_id = b.id)    as last_checked_at,
  c.user_id                                                                 as captured_by,
  r.user_id                                                                 as last_reported_by
from public.bays b
left join public.captures c
  on c.bay_id = b.id and c.ended_at is null
left join lateral (
  select l.status, l.created_at, l.user_id,
         -- people who agreed since the status last flipped
         (select count(distinct x.user_id)::int
            from public.reports x
           where x.bay_id = b.id
             and x.status = l.status
             and x.created_at > now() - interval '20 minutes'
             and x.created_at > coalesce(
                   (select max(y.created_at) from public.reports y
                     where y.bay_id = b.id and y.status <> l.status),
                   '-infinity')) as confirmations
    from public.reports l
   where l.bay_id = b.id
     and l.created_at > now() - interval '20 minutes'
   order by l.created_at desc
   limit 1
) r on true;

grant select on public.bay_status to anon, authenticated;

-- ---------- Live updates ----------
alter publication supabase_realtime add table public.bays, public.reports, public.captures;
