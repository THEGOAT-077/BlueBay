-- =====================================================================
-- BlueBay database, part 2 of 2: accounts and votes
-- Run once in the Supabase SQL Editor, after part 1.
--
--   profiles        public part of each account (display name). Emails and
--                   passwords stay in Supabase's own auth tables.
--   pin_votes       up/down vote on a pin: is the bay real and in the right place?
--   user_votes      up/down vote on a person: are their reports accurate?
--   profile_scores  each person's total score
--   bay_status      replaced with a fuller version: score, your vote, names
-- =====================================================================

-- ---------- profiles ----------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text not null check (char_length(btrim(display_name)) between 2 and 30),
  created_at    timestamptz not null default now()
);
alter table public.profiles enable row level security;

revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant update (display_name) on public.profiles to authenticated;

create policy "Anyone can read profiles"
  on public.profiles for select to anon, authenticated using (true);
create policy "Users rename only themselves"
  on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Every new account (including anonymous ones) gets a name like "Driver 4f2a".
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, 'Driver ' || substr(replace(new.id::text, '-', ''), 1, 4))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Accounts that already exist get a profile too.
insert into public.profiles (id, display_name)
select id, 'Driver ' || substr(replace(id::text, '-', ''), 1, 4) from auth.users
on conflict (id) do nothing;

-- ---------- pin votes ----------
create table public.pin_votes (
  bay_id      uuid not null references public.bays (id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  vote        smallint not null check (vote in (-1, 1)),   -- 1 = real and correct, -1 = wrong
  created_at  timestamptz not null default now(),
  primary key (bay_id, user_id)                             -- one vote per person per pin
);
alter table public.pin_votes enable row level security;

revoke all on public.pin_votes from anon, authenticated;
grant select on public.pin_votes to anon, authenticated;
grant insert (bay_id, vote), update (vote), delete on public.pin_votes to authenticated;

create policy "Anyone can read pin votes"
  on public.pin_votes for select to anon, authenticated using (true);
create policy "Vote as yourself, not on a pin you dropped"
  on public.pin_votes for insert to authenticated
  with check (
    user_id = auth.uid()
    and not exists (select 1 from public.bays b
                     where b.id = pin_votes.bay_id and b.created_by = auth.uid())
  );
create policy "Change only your own pin vote"
  on public.pin_votes for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Remove only your own pin vote"
  on public.pin_votes for delete to authenticated
  using (user_id = auth.uid());

-- ---------- user votes ----------
create table public.user_votes (
  voter_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  target_id   uuid not null references public.profiles (id) on delete cascade,
  vote        smallint not null check (vote in (-1, 1)),   -- 1 = accurate, -1 = misleading
  created_at  timestamptz not null default now(),
  primary key (voter_id, target_id),                        -- one vote per pair of users
  check (voter_id <> target_id)                             -- never on yourself
);
alter table public.user_votes enable row level security;
create index user_votes_target on public.user_votes (target_id);

revoke all on public.user_votes from anon, authenticated;
grant select on public.user_votes to anon, authenticated;
grant insert (target_id, vote), update (vote), delete on public.user_votes to authenticated;

create policy "Anyone can read user votes"
  on public.user_votes for select to anon, authenticated using (true);
create policy "Vote on others as yourself"
  on public.user_votes for insert to authenticated
  with check (voter_id = auth.uid() and target_id <> auth.uid());
create policy "Change only your own user vote"
  on public.user_votes for update to authenticated
  using (voter_id = auth.uid()) with check (voter_id = auth.uid());
create policy "Remove only your own user vote"
  on public.user_votes for delete to authenticated
  using (voter_id = auth.uid());

-- ---------- each person's score ----------
create view public.profile_scores with (security_invoker = true) as
select p.id, p.display_name,
       coalesce(sum(v.vote), 0)::int                  as score,
       count(v.vote) filter (where v.vote = 1)::int   as upvotes,
       count(v.vote) filter (where v.vote = -1)::int  as downvotes
  from public.profiles p
  left join public.user_votes v on v.target_id = p.id
 group by p.id, p.display_name;

grant select on public.profile_scores to anon, authenticated;

-- ---------- fuller bay_status (replaces the one from part 1) ----------
drop view public.bay_status;

create view public.bay_status with (security_invoker = true) as
select
  b.id, b.name, b.lat, b.lng, b.source, b.osm_ref, b.created_by,
  case when c.id is not null then 'taken' else coalesce(r.status, 'unk') end as status,
  case when c.id is not null then c.started_at else r.created_at end         as status_at,
  case when c.id is not null then 1 else coalesce(r.confirmations, 0) end   as confirmations,
  (select max(x.created_at) from public.reports x where x.bay_id = b.id)    as last_checked_at,
  -- pin votes
  coalesce(pv.score, 0)     as score,
  coalesce(pv.upvotes, 0)   as upvotes,
  coalesce(pv.downvotes, 0) as downvotes,
  (select v.vote from public.pin_votes v
    where v.bay_id = b.id and v.user_id = auth.uid())                        as my_vote,
  -- who holds it / who last reported it, with their names
  c.user_id                 as captured_by,
  cp.display_name           as captured_by_name,
  r.user_id                 as last_reported_by,
  rp.display_name           as last_reported_by_name
from public.bays b
left join public.captures c
  on c.bay_id = b.id and c.ended_at is null
left join lateral (
  select l.status, l.created_at, l.user_id,
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
) r on true
left join lateral (
  select sum(v.vote)::int                              as score,
         count(*) filter (where v.vote = 1)::int       as upvotes,
         count(*) filter (where v.vote = -1)::int      as downvotes
    from public.pin_votes v where v.bay_id = b.id
) pv on true
left join public.profiles cp on cp.id = c.user_id
left join public.profiles rp on rp.id = r.user_id;

grant select on public.bay_status to anon, authenticated;

-- ---------- Live updates ----------
alter publication supabase_realtime add table public.profiles, public.pin_votes, public.user_votes;
