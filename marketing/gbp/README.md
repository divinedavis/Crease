# Google Business Profile assets

The listing is a **service-area business** — no storefront, so there is no exterior
photo to upload and the "Add a storefront photo" step is skipped on purpose. These
two files go in the profile's Photos section, into the Logo and Cover slots.

| File | Size | Slot |
| --- | --- | --- |
| `crease-logo-720.png` | 720×720 | Logo — Google's recommended resolution (minimum 250×250) |
| `crease-cover-1200x675.png` | 1200×675 | Cover — 16:9 |
| `crease-photo-1.png` | 1200×900 | Gallery — how it works |
| `crease-photo-2.png` | 1200×900 | Gallery — what it costs |
| `crease-photo-3.png` | 1200×900 | Gallery — where we collect |
| `crease-photo-4.png` | 1200×900 | Gallery — what we take |

All six are well inside Google's 10 KB–5 MB range.

## Regenerating

The logo is a straight render of the iOS app icon, so the mark stays identical
across the App Store, the website and Google. Do not draw a second one.

```sh
rsvg-convert -w 720 -h 720 apps/web/public/assets/icon.svg -o marketing/gbp/crease-logo-720.png
rsvg-convert -w 1200 -h 675 marketing/gbp/cover.svg        -o marketing/gbp/crease-cover-1200x675.png
```

`cover.svg` inlines the hanger paths from `apps/web/public/assets/icon.svg` rather
than importing it, because rsvg does not resolve `<use href>` across files. If the
icon ever changes, the two paths here have to be copied over by hand.

## The four gallery cards

Every number on them is read out of the code, not from memory, so they cannot
quietly drift from what the app will charge:

- `$2.00/lb`, `$20 minimum` — `apps/web/app/order/order-form.tsx`
- `$29.95` round trip, `$16.95` pickup-only and return-only — `apps/web/lib/tiers.ts`,
  itself mirrored from `services/dispatch/src/pricing.ts`
- the 29 neighbourhoods and the three-mile band — `apps/web/lib/neighborhoods.ts`

If any of those change, regenerate. The generator lives in this repo's history;
the cards are plain SVG rendered through `rsvg-convert` at 1200×900.

The iOS App Store panels in `apps/ios/marketing/panels/` are deliberately NOT
reused here. They are headlined "dry cleaning without the errand", and dry
cleaning is the one service this listing must not advertise — see T006 in
`growth/techniques.json`.

## Still missing

Google's photo guidance prefers images that represent reality, and profiles with
real photographs earn materially more clicks than ones carrying only a logo. A
branded cover is a placeholder. Shoot the real thing on a pickup: a courier at a
doorstep, folded laundry, the tote bags.
