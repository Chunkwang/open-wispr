-- 0002_referrals.sql
--
-- Task 7.3: Referral schema & per-user referral code.
--
-- 1. Adds referral_code to public.profiles if not present.
-- 2. Creates public.referrals table to track redemption pairs.

alter table public.profiles
  add column if not exists referral_code text unique;

-- Backfill referral codes for existing profiles without one
update public.profiles
  set referral_code = substring(md5(random()::text || id::text) from 1 for 8)
  where referral_code is null;

-- Ensure default for new profiles
alter table public.profiles
  alter column referral_code set default substring(md5(random()::text) from 1 for 8);

-- Table to track successful referral redemptions
create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references public.profiles (id) on delete cascade,
  referee_id uuid not null references public.profiles (id) on delete cascade,
  code text not null,
  created_at timestamptz not null default now(),
  constraint unique_referee unique (referee_id),
  constraint no_self_referral check (referrer_id != referee_id)
);

alter table public.referrals enable row level security;

revoke all on public.referrals from anon, authenticated;
grant select on public.referrals to authenticated;
grant all on public.referrals to service_role;

-- Grant select on referral_code to authenticated users so they can view their own code
grant select (referral_code) on public.profiles to authenticated;
