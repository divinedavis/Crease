-- Bot submissions through the web pickup form (crypto-scam links in the name,
-- six random characters in every other field) were counted as people waiting
-- on a call back. 'spam' keeps the row for the record and takes it out of
-- every request count on the owner dashboard.
alter table public.pickup_requests drop constraint if exists pickup_requests_status_check;
alter table public.pickup_requests add constraint pickup_requests_status_check
  check (status in ('new', 'contacted', 'booked', 'declined', 'spam'));

-- The two received so far (2026-09-13, 2026-09-24): a link in the name and an
-- address with no space in it. No real request matches both.
update public.pickup_requests
   set status = 'spam', updated_at = now()
 where status = 'new'
   and name ~* '(https?://|www\.|[a-z0-9-]+\.(org|com|net|io|ru|xyz)/)'
   and address !~ '\s';
