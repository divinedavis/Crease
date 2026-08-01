-- The authorize path upserts on (order_id, kind); postgres needs a matching
-- unique constraint for ON CONFLICT to resolve.
create unique index if not exists payments_order_kind_idx on public.payments(order_id, kind);
notify pgrst, 'reload schema';
