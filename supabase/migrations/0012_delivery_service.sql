-- Crease sells transport, not cleaning.
--
-- The customer settles the cleaning bill with the shop directly, so an order's
-- own price is the courier fee and nothing else. The columns that modelled a
-- marketplace markup are left in place but are no longer what an order is
-- priced on — delivery_fee_cents is.

alter table public.orders
  add column service_tier text not null default 'round_trip'
    check (service_tier in ('round_trip','return_only','pickup_only'));

-- Nothing should be bookable at zero. A default of 0 meant every order placed
-- so far was free, which is a pricing bug wearing the costume of a default.
alter table public.orders
  alter column delivery_fee_cents set default 0;

comment on column public.orders.delivery_fee_cents is
  'What Crease charges for transport. This is the whole price of an order; the cleaning is settled with the shop.';
comment on column public.orders.service_tier is
  'round_trip = both courier legs, return_only / pickup_only = one leg.';

notify pgrst, 'reload schema';
