# Google Business Profile assets

The listing is a **service-area business** — no storefront, so there is no exterior
photo to upload and the "Add a storefront photo" step is skipped on purpose. These
two files go in the profile's Photos section, into the Logo and Cover slots.

| File | Size | Slot |
| --- | --- | --- |
| `crease-logo-720.png` | 720×720 | Logo — Google's recommended resolution (minimum 250×250) |
| `crease-cover-1200x675.png` | 1200×675 | Cover — 16:9 |

Both are well inside Google's 10 KB–5 MB range.

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

## Still missing

Google's photo guidance prefers images that represent reality, and profiles with
real photographs earn materially more clicks than ones carrying only a logo. A
branded cover is a placeholder. Shoot the real thing on a pickup: a courier at a
doorstep, folded laundry, the tote bags.
