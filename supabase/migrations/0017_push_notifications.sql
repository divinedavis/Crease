-- Telling a customer their clothes are done.
--
-- Every other thing that happens to an order either follows something the
-- customer just did or is visible on a screen they are already looking at.
-- Ready is the exception: it lands in the middle of a working day, hours after
-- the app was closed, and there is nothing in the product that would ever tell
-- them. That is the whole case for a push, and the reason these two tables
-- exist at all.
--
-- Two tables because "who to reach" and "what has already been said" fail
-- differently. A stale device token wastes one send. A missing ledger sends the
-- same person the same thing twice, which is exactly what a retried webhook, a
-- double-clicked button, or a second status write does by default.

create table public.device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  -- The token is the key, not (user_id, token). A device outlives the account
  -- signed into it: reinstalls, a phone handed down, an account switched in the
  -- app. Keyed the other way both rows survive, APNs accepts the old one, and
  -- the previous owner keeps getting somebody else's laundry.
  token        text not null unique,
  platform     text not null default 'ios' check (platform in ('ios')),
  -- A TestFlight build talks to production APNs and a Debug build to sandbox,
  -- and a token minted against one is meaningless to the other. Only the device
  -- knows which it registered with, so it tells us rather than us guessing from
  -- a build flag — guessing is the classic silent failure here.
  environment  text not null check (environment in ('sandbox','production')),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create index device_tokens_user_idx on public.device_tokens(user_id);

create table public.notifications_sent (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.orders on delete cascade,
  user_id      uuid not null references auth.users on delete cascade,
  kind         text not null check (kind in ('ready')),
  -- Devices actually reached. Zero is a real answer — permission never granted,
  -- or every token pruned — and is worth telling apart from a send that failed.
  device_count int not null default 0,
  last_error   text,
  sent_at      timestamptz not null default now()
);

-- A claim, not a receipt: the row is written before the push is sent, so two
-- callers racing on the same transition cannot both get past it. The kind is
-- checked rather than free text because a typo would key a second ledger entry
-- that dedupes against nothing, which is the one failure this table exists to
-- prevent.
create unique index notifications_sent_order_kind_idx
  on public.notifications_sent(order_id, kind);

alter table public.device_tokens      enable row level security;
alter table public.notifications_sent enable row level security;

-- A customer may see and forget their own devices. Registration goes through
-- the dispatcher instead, because moving a token from one account to another is
-- a decision about somebody else's row.
create policy device_tokens_self on public.device_tokens
  for select to authenticated using (user_id = auth.uid());
create policy device_tokens_forget on public.device_tokens
  for delete to authenticated using (user_id = auth.uid());

-- notifications_sent intentionally has NO policy, like delivery_events:
-- default-deny for anon and authenticated. It is the dispatcher's bookkeeping,
-- and a client that could read it learns nothing it cannot already see.

grant select, delete                 on public.device_tokens      to authenticated;
grant select, insert, update, delete on public.device_tokens      to service_role;
grant select, insert, update, delete on public.notifications_sent to service_role;

comment on column public.device_tokens.environment is
  'Which APNs the device registered against. TestFlight and App Store builds '
  'are ''production''; only a Debug build from Xcode is ''sandbox''.';
comment on table public.notifications_sent is
  'Idempotency ledger, one row per (order, kind). Claimed before the send.';

notify pgrst, 'reload schema';
