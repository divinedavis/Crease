-- Payments become provider-agnostic, and an order can now carry more than one
-- of them.
--
-- The second part matters: when the cleaner counts more garments than the
-- customer estimated, card networks will not let us capture above the
-- original hold. The difference has to be a separate charge, taken only after
-- the customer approves it. So `payments` is one-to-many on orders, with
-- `kind` distinguishing the original hold from the top-up.

alter table public.payments rename column stripe_payment_intent_id to provider_intent_ref;

alter table public.payments
  add column provider text not null default 'mock',
  add column kind text not null default 'primary'
    check (kind in ('primary', 'difference'));

-- At most one primary hold per order; any number of difference charges.
create unique index payments_one_primary_idx
  on public.payments(order_id) where kind = 'primary';

create index payments_provider_ref_idx on public.payments(provider, provider_intent_ref);

-- Saved payment credentials live on the profile, as opaque provider handles.
-- No card data ever touches this database.
alter table public.profiles
  add column payment_customer_ref text,
  add column default_payment_method_ref text;

-- Customers approving a higher intake total need to be able to record that
-- decision. The existing orders_customer_update policy already restricts them
-- to their own order in 'awaiting_approval'; this widens nothing.
comment on column public.orders.approved_at is
  'Set when the customer accepted an intake total above the authorized hold.';

notify pgrst, 'reload schema';
