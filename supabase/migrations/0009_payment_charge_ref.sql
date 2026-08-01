-- Store the charge behind each captured payment.
--
-- Transfers to a shop are funded with `source_transaction` set to the charge,
-- which lets Stripe move money directly from that charge rather than from the
-- platform's available balance. Without it, payouts fail on a young account
-- (zero balance) or lag settlement on a busy one — failures that have nothing
-- to do with the order and are confusing to diagnose.

alter table public.payments add column charge_ref text;
create index payments_charge_ref_idx on public.payments(charge_ref) where charge_ref is not null;

notify pgrst, 'reload schema';
