-- Backstop for double-dispatch.
--
-- The existing partial unique index only prevents two *live* legs of the same
-- type. It does not stop a second courier being sent after the first leg has
-- already completed — which is exactly the expensive mistake: a duplicated
-- "dispatch pickup" call routes a courier to the customer's door for a bag
-- that is already sitting at the cleaner, and we are billed for the trip.
--
-- The dispatcher guards this in application code; this index makes it
-- impossible even if a future code path forgets.

create unique index delivery_legs_one_delivered_idx
  on public.delivery_legs(order_id, leg)
  where status = 'delivered';

notify pgrst, 'reload schema';
