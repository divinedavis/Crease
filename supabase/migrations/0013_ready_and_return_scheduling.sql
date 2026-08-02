-- Who knows what, and when.
--
-- The booking screen was quoting "~30 min" for a round trip, which is not a
-- number anyone can know: it implied the whole cycle — collect, clean, return —
-- took half an hour, when the cleaning alone takes days and only the shop can
-- say how long. The only honest estimate at booking is how long until a driver
-- reaches the customer.
--
-- So the timeline is split by who actually holds the information:
--   at booking   we estimate the pickup driver's arrival, nothing else
--   at intake    the shop says when it expects to be finished
--   when done    the shop marks it ready
--   after that   the customer chooses when they want it back

alter table public.orders
  -- The shop's own estimate, set at intake. Null until they say.
  add column estimated_ready_at timestamptz,
  -- When the shop actually marked it done, which is what unlocks scheduling
  -- the return. Distinct from estimated_ready_at: one is a promise, the other
  -- is a fact, and conflating them is how a customer gets told their clothes
  -- are ready when they are not.
  add column ready_at timestamptz;

comment on column public.orders.estimated_ready_at is
  'Shop''s estimate of when cleaning will be finished. A promise, not a fact.';
comment on column public.orders.ready_at is
  'Set when the shop marks the order ready. Until this exists the customer cannot schedule a return.';
comment on column public.orders.return_window_start is
  'Chosen by the customer AFTER the order is ready — not guessed at booking time.';

create index orders_awaiting_return_idx on public.orders(ready_at)
  where ready_at is not null and return_window_start is null;

notify pgrst, 'reload schema';
