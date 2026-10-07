-- The photo weight estimate a customer accepted for a wash & fold bag, and how
-- it was made. Kept so the counter's real weigh-in can be compared with it
-- (scripts/weight-calibration.mjs) and the app's numbers tuned from evidence
-- rather than from laundry-guide averages.
alter table public.orders
  add column if not exists weight_estimate_lb numeric(5,1)
    check (weight_estimate_lb is null or (weight_estimate_lb > 0 and weight_estimate_lb <= 200)),
  add column if not exists weight_estimate_method text
    check (weight_estimate_method is null or weight_estimate_method in ('container', 'lidar'));

-- Customers set these once, at insert (0022 locks INSERT to listed columns).
grant insert (weight_estimate_lb, weight_estimate_method) on public.orders to authenticated;

notify pgrst, 'reload schema';
