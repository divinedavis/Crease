# Brooklyn canvass list

Street tool at https://crease.divinedavis.com/prospects/ — every dry cleaner
and laundromat in Brooklyn, grouped by neighborhood, with visited checkoffs,
an outcome per shop, and notes. Used to ask each one whether they'll accept
deliveries from the app. Dry cleaners and laundromats are worked as separate
lists — the segmented filter is a mode, not a search.

- **Data**: OpenStreetMap via Overpass (`shop=dry_cleaning` + `shop=laundry`
  inside the Brooklyn admin boundary), assigned to NYC NTA-2020 neighborhoods
  by point-in-polygon. Free; no Places API spend. `seed.json` is the frozen
  pull; `node scripts/seed-prospects.mjs` upserts it on `osm_id` and never
  touches `visited` / `outcome` / `notes`, so reseeding cannot erase fieldwork.
- **Access**: `prospects` table in the Crease Supabase project. RLS allowlists
  the canvasser logins only — shop staff and app customers authenticate
  against this same project and must not see the list (or the notes about
  them). Password lives in keychain `crease-canvass-password`.
- **Deploy**: `./deploy/deploy-prospects.sh` — substitutes the Supabase URL +
  anon key into a staged copy (never committed) and ships it to the droplet.
  nginx serves the directory at `/prospects/`.

To refresh the shop list later, re-run the Overpass query (see git history of
seed.json for the exact query) and reseed.
