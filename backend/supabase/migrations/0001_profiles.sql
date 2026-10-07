-- 0001_profiles.sql
--
-- One row per signed-in user: their tier and Stripe customer id. Re-runnable.
-- Design: docs/auth-design.md section 5. Checked offline by
-- backend/supabase/scripts/check-migration.mjs (PGlite), and still to be run against
-- the real Supabase project with a real user token on Day 16.
--
-- Who may do what:
--   * The Worker uses the service-role key (role service_role, which bypasses RLS) to read
--     the tier and, from the Stripe webhook, to write tier and stripe_customer_id.
--   * A signed-in user (role authenticated) may read ONLY their own id and tier. They can
--     not write anything, and can not even select stripe_customer_id.
--   * anon (no session) can do nothing.
--
-- Supabase's default privileges grant ALL on every new public table to anon and
-- authenticated, so the explicit REVOKE below is the real protection. RLS with no
-- write policy is a second layer: it does not replace the revoke.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  tier text not null default 'free' check (tier in ('free', 'pro')),
  stripe_customer_id text unique,
  created_at timestamptz not null default now()
);
-- No email column on purpose: it lives in auth.users, and this table is not the place for it.

alter table public.profiles enable row level security;

-- The only policy: read your own row. There is no insert, update or delete policy.
drop policy if exists "profiles: read own row" on public.profiles;
create policy "profiles: read own row"
  on public.profiles
  for select
  to authenticated
  using ((select auth.uid()) = id);

-- Privileges. Start from nothing for the client-facing roles, then grant back only the
-- read of two columns (this hides stripe_customer_id from the user's own token).
revoke all on public.profiles from anon, authenticated;
grant select (id, tier) on public.profiles to authenticated;
-- The Worker's role keeps full access (it bypasses RLS anyway; be explicit about the grant).
grant all on public.profiles to service_role;

-- New users get a Free profile automatically. SECURITY DEFINER so it works whoever inserts
-- into auth.users; empty search_path with every reference schema-qualified so nothing
-- can be hijacked through a same-named object in another schema.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

-- Nobody calls it directly: only the trigger runs it.
revoke execute on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Users who signed up before this migration (or while the trigger did not exist).
-- Never overwrites an existing row, so re-running does not reset anyone's tier.
insert into public.profiles (id)
select id from auth.users
on conflict do nothing;
