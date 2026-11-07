-- =====================================================================
-- BlueBay database, part 3: only signed-in (non-guest) users can vote
-- Run once in the Supabase SQL Editor, after parts 1 and 2.
--
-- Guests (anonymous sign-in) can still look, report Free/Taken, capture
-- and release. Voting on pins and people needs an email or Google login,
-- so nobody can farm votes with throwaway guest accounts.
-- =====================================================================

-- true for a guest session, false for a real login
create or replace function public.is_guest() returns boolean
language sql stable set search_path = '' as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, true)
$$;

-- ---------- pin votes ----------
drop policy "Vote as yourself, not on a pin you dropped" on public.pin_votes;
create policy "Signed-in users vote as themselves, not on a pin they dropped"
  on public.pin_votes for insert to authenticated
  with check (
    user_id = auth.uid()
    and not public.is_guest()
    and not exists (select 1 from public.bays b
                     where b.id = pin_votes.bay_id and b.created_by = auth.uid())
  );

drop policy "Change only your own pin vote" on public.pin_votes;
create policy "Signed-in users change only their own pin vote"
  on public.pin_votes for update to authenticated
  using (user_id = auth.uid() and not public.is_guest())
  with check (user_id = auth.uid());

-- ---------- user votes ----------
drop policy "Vote on others as yourself" on public.user_votes;
create policy "Signed-in users vote on others as themselves"
  on public.user_votes for insert to authenticated
  with check (voter_id = auth.uid() and target_id <> auth.uid() and not public.is_guest());

drop policy "Change only your own user vote" on public.user_votes;
create policy "Signed-in users change only their own user vote"
  on public.user_votes for update to authenticated
  using (voter_id = auth.uid() and not public.is_guest())
  with check (voter_id = auth.uid());

-- Removing your own vote stays allowed for everyone.
