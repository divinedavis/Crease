-- A second notification kind: the shop has opened and counted the bag.
--
-- 'ready' tells the customer the clothes are done; 'received' tells them the
-- handoff worked — the one moment of doubt in a model where a stranger walks
-- off with your laundry. The kind stays a CHECK rather than free text for the
-- same reason as before: a typo would key a ledger row that dedupes against
-- nothing.

alter table public.notifications_sent
  drop constraint notifications_sent_kind_check;
alter table public.notifications_sent
  add constraint notifications_sent_kind_check check (kind in ('ready', 'received'));

notify pgrst, 'reload schema';
