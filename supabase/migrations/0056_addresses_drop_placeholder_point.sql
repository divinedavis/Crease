-- A saved address must never carry the app's "somewhere in Brooklyn"
-- placeholder as if it were the door.
--
-- iOS Address.asResolved filled a missing lat/lng with
-- CLLocationCoordinate2D.brooklyn (40.7178, -73.9569, Williamsburg), and the
-- booking flow then wrote that point back to the row. On 2026-11-22 four of
-- the six saved addresses held it — the founder's 251 DeKalb Ave three times —
-- so a booking from "Home" measured 2.4 miles to Fulton Cleaners instead of
-- 0.4 and the pin opened in the wrong neighbourhood. Those rows were
-- re-geocoded by hand the same day (Census geocoder).
--
-- The app is fixed too, but builds already installed keep sending the
-- placeholder, so the database drops it: the point becomes NULL ("not known
-- yet"), which the fixed app geocodes and asks the customer to confirm. NULL,
-- not a rejected write, so an old build's booking still goes through.

create or replace function public.addresses_drop_placeholder_point()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.lat is not null and new.lng is not null
     and abs(new.lat - 40.7178) < 0.00005 and abs(new.lng + 73.9569) < 0.00005 then
    new.lat := null;
    new.lng := null;
  end if;
  return new;
end;
$$;
revoke all on function public.addresses_drop_placeholder_point() from public, anon, authenticated;

drop trigger if exists addresses_drop_placeholder_point on public.addresses;
create trigger addresses_drop_placeholder_point
  before insert or update of lat, lng on public.addresses
  for each row execute function public.addresses_drop_placeholder_point();
