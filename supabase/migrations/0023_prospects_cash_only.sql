-- Whether the shop takes cash only ("does card payment" was already being
-- tracked in canvass notes). A cash-only shop can still partner — Crease
-- charges the customer and pays the shop out through Connect — but it
-- signals how far from card-rail habits the owner is, and the pitch has to
-- meet them there. Two-valued like own_app: true (confirmed at the
-- counter) or null (unknown); card acceptance is the default assumption.

alter table public.prospects add column cash_only boolean;

notify pgrst, 'reload schema';
