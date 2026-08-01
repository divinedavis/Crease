-- Paying partner cleaners.
--
-- One payout per order, created only after the customer's money is actually
-- captured. It is a separate row rather than a column on `orders` because a
-- payout has its own lifecycle: it can be pending while a shop finishes
-- onboarding, it can fail on its own, and it needs its own audit trail when
-- a shop asks why a number differs from what they expected.

create table public.payouts (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders on delete restrict,
  cleaner_id     uuid not null references public.cleaners on delete restrict,
  status         text not null default 'pending'
                   check (status in ('pending','paid','failed','skipped')),
  provider       text not null default 'mock',
  provider_transfer_ref text,

  -- Snapshotted, not derived. A shop that renegotiates its rate must not
  -- retroactively change what it was paid on past orders, and a subtotal can
  -- be corrected after the fact.
  subtotal_cents   int not null,
  commission_bps   int not null,
  amount_cents     int not null,

  last_error     text,
  paid_at        timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- At most one payout per order. The transfer itself is also idempotent on the
-- payout row id, so a retry after a timeout cannot pay a shop twice.
create unique index payouts_one_per_order_idx on public.payouts(order_id);
create index payouts_cleaner_idx on public.payouts(cleaner_id, created_at desc);
create index payouts_unsettled_idx on public.payouts(status) where status in ('pending','failed');

create trigger payouts_touch before update on public.payouts
  for each row execute function public.touch_updated_at();

alter table public.payouts enable row level security;

-- Shops can see their own payouts; nobody else can. Customers have no
-- business seeing what a cleaner is paid.
create policy payouts_cleaner_read on public.payouts
  for select to authenticated using (public.is_cleaner_staff(cleaner_id));

grant select on public.payouts to authenticated;
grant select, insert, update, delete on public.payouts to service_role;

-- Connect onboarding state, so the portal can nag a shop that cannot be paid.
alter table public.cleaners
  add column payouts_enabled boolean not null default false,
  add column connect_requirements jsonb not null default '[]'::jsonb;

notify pgrst, 'reload schema';
