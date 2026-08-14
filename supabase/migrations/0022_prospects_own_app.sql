-- Whether the shop already runs its own ordering/delivery app. Canvassing
-- keeps surfacing these ("they have their own order app" was living in
-- free-text notes), and it changes the pitch entirely: these shops already
-- believe in delivery — the sell is switching, not convincing. Two-valued
-- on purpose: true (seen or told at the counter) and null — unknown. A
-- confirmed "no app" isn't worth a column; that's just the default pitch.

alter table public.prospects add column own_app boolean;

notify pgrst, 'reload schema';
