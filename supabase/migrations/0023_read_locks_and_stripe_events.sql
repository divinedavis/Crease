-- Fourth-pass hardening: read-side column locks, the Stripe event ledger, and
-- the difference-charge index contradiction.

-- =========================================================================
-- Auth #3 (MEDIUM) — cleaners_read is USING (active), so EVERY authenticated
-- customer could read each shop's commission rate and Connect internals.
-- Lock the read grant to the columns a client legitimately needs.
--
-- Note: stripe_account_id and payouts_enabled STAY granted because the portal
-- settings page renders payout status under the staff member's own session
-- (RLS still scopes rows to shops they staff). commission_bps and
-- connect_requirements have no client reader at all — those are the ones a
-- customer could mine, so they become service_role-only.
-- =========================================================================
revoke select on public.cleaners from authenticated;
grant select (
  id, name, slug, phone, email, line1, line2, city, state, postal_code,
  country, lat, lng, service_radius_miles, turnaround_hours, hours,
  active, created_at, stripe_account_id, payouts_enabled
) on public.cleaners to authenticated;

-- =========================================================================
-- Payments #6 (MEDIUM) — 0005 deliberately allows many 'difference' rows per
-- order (a second intake overage needs a second top-up) via a partial unique
-- index on kind='primary'. 0006 then added a FULL unique(order_id, kind),
-- which caps difference charges at one and makes the second top-up crash the
-- approve flow. Drop the over-broad index; the partial one from 0005 keeps the
-- single-primary guarantee the upserts rely on.
-- =========================================================================
drop index if exists public.payments_order_kind_idx;

-- Keep ON CONFLICT (order_id, kind) working for the primary upserts: a partial
-- unique index on kind='primary' is a valid conflict target for those calls.
create unique index if not exists payments_one_primary_idx
  on public.payments (order_id, kind) where kind = 'primary';

-- =========================================================================
-- Payments #4 (MEDIUM) — Stripe webhook had no idempotency ledger, so a
-- replayed (validly-signed) event re-ran dispatch. Give it one.
-- =========================================================================
create table if not exists public.stripe_events (
  event_id     text primary key,
  type         text,
  livemode     boolean,
  received_at  timestamptz not null default now(),
  processed_at timestamptz,
  error        text
);
alter table public.stripe_events enable row level security;  -- service_role only
revoke all on public.stripe_events from anon, authenticated;

-- =========================================================================
-- Dispatch #9 (LOW) — delivery_events keeps raw courier payloads (names,
-- phones, dropoff PINs) forever. Give operators a purge they can schedule.
-- =========================================================================
create or replace function public.purge_delivery_events(p_days integer default 90)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  n integer;
begin
  delete from public.delivery_events
  where received_at < now() - make_interval(days => p_days)
  returning 1 into n;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.purge_delivery_events(integer) from public, anon, authenticated;
grant execute on function public.purge_delivery_events(integer) to service_role;
