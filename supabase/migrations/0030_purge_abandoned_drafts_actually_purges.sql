-- purge_abandoned_drafts (0027) excluded any draft that had ever created a
-- payment row, on the reasoning that "money means it is not abandoned". But the
-- app mints the PaymentIntent in the same tap that creates the draft, so nearly
-- every draft has one: 31 of 34 live drafts were excluded, and the job that was
-- supposed to keep the draft cap meaningful cleaned up almost nothing.
--
-- What actually distinguishes an abandoned checkout is that the intent was
-- never paid. A row still at 'requires_payment_method' is a customer who
-- opened the sheet and walked away; anything further along is real money and
-- must never be swept. Stripe expires its own unpaid intents, so deleting our
-- side of one strands nothing.
create or replace function public.purge_abandoned_drafts(p_days integer default 30)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  n integer;
begin
  delete from public.orders o
   where o.status = 'draft'
     and o.created_at < now() - make_interval(days => p_days)
     -- No payment that ever got past "the sheet was opened". Anything
     -- authorized, captured, refunded or even failed is money that happened and
     -- is somebody's problem to look at, not a row to delete quietly.
     and not exists (
       select 1 from public.payments p
        where p.order_id = o.id
          and p.status <> 'requires_payment_method'
     );
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.purge_abandoned_drafts(integer) from public, anon, authenticated;
grant execute on function public.purge_abandoned_drafts(integer) to service_role;
