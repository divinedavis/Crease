-- purge_delivery_events() has failed every week since 2026-11-01 with
-- "query returned more than one row". 0023 wrote the delete as
--
--   delete from public.delivery_events where ... returning 1 into n;
--
-- and in plpgsql a DML statement with RETURNING ... INTO raises as soon as it
-- touches more than one row. It passed for months only because nothing was
-- 90 days old yet (0 rows). The first Sunday that two events crossed the line
-- the function raised, the delete rolled back, and from then on no raw courier
-- payload (customer addresses, courier phones, dropoff PINs) was purged: 327
-- of 745 rows were past retention when this was found on 2026-11-10.
--
-- The count already comes from GET DIAGNOSTICS, so the RETURNING clause was
-- never needed. Same signature, owner and grants (postgres, service_role).

create or replace function public.purge_delivery_events(p_days integer default 90)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  n integer;
begin
  delete from public.delivery_events
  where received_at < now() - make_interval(days => p_days);
  get diagnostics n = row_count;
  return n;
end;
$$;
