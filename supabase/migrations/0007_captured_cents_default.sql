-- captured_cents was nullable with no default while refunded_cents already
-- defaulted to 0. That inconsistency is a live hazard, not a cosmetic one:
-- approveAndCharge sums primary.captured_cents + difference.captured_cents,
-- and a NULL in either term makes the total NULL rather than a number — a
-- silent wrong answer about how much a customer was charged.
--
-- "Nothing captured" is a real quantity: zero.

update public.payments set captured_cents = 0 where captured_cents is null;

alter table public.payments
  alter column captured_cents set default 0,
  alter column captured_cents set not null;

-- Same reasoning for the hold: it is always known at insert.
update public.payments set authorized_cents = 0 where authorized_cents is null;
alter table public.payments
  alter column authorized_cents set default 0,
  alter column authorized_cents set not null;

notify pgrst, 'reload schema';
