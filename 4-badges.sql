-- =====================================================================
-- BlueBay database, part 4: badges, and sign-in to add a bay
-- Run once in the Supabase SQL Editor, after parts 1 to 3.
--
-- Points: for every bay a person added themselves (not OpenStreetMap imports)
--   more upvotes than downvotes   -> +1 point
--   more downvotes than upvotes   -> -1 point
--   a tie (or no votes yet)       ->  0
-- The total never goes below 0.
--
-- Badges: Blue 0-9, Bronze 10+, Silver 20+, Gold 30+, Platinum 50+
-- =====================================================================

-- ---------- Only signed-in users can add their own bays ----------
-- Guests can still import mapped bays from OpenStreetMap ("Find bays here").
drop policy "Signed-in users add bays as themselves" on public.bays;
create policy "Signed-in users add bays; guests only import mapped ones"
  on public.bays for insert to authenticated
  with check (created_by = auth.uid() and (source = 'osm' or not public.is_guest()));

-- ---------- Badge for a number of points ----------
create or replace function public.badge_for(points int) returns text
language sql immutable set search_path = '' as $$
  select case when points >= 50 then 'platinum'
              when points >= 30 then 'gold'
              when points >= 20 then 'silver'
              when points >= 10 then 'bronze'
              else 'blue' end
$$;

-- ---------- Each person's points and badge ----------
create view public.profile_badges with (security_invoker = true) as
with pin as (
  select b.created_by as owner, b.id as bay_id, coalesce(sum(v.vote), 0) as net
    from public.bays b
    left join public.pin_votes v on v.bay_id = b.id
   where b.source = 'user' and b.created_by is not null
   group by b.created_by, b.id
), totals as (
  select p.id, p.display_name,
         count(pin.bay_id)::int                       as pins_added,
         count(pin.bay_id) filter (where pin.net > 0)::int as pins_up,
         count(pin.bay_id) filter (where pin.net < 0)::int as pins_down,
         greatest(0, coalesce(sum(sign(pin.net)), 0))::int as points
    from public.profiles p
    left join pin on pin.owner = p.id
   group by p.id, p.display_name
)
select t.*, public.badge_for(t.points) as badge
  from totals t;

grant select on public.profile_badges to anon, authenticated;
