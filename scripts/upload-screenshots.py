#!/usr/bin/env python3
"""Upload App Store screenshots through the App Store Connect API.

Screenshots are one of the few App Store assets the API does handle end to end,
so there is no reason to drag files into a browser. The upload is a three-step
dance per image — reserve, PUT the bytes to the URLs Apple hands back, then
commit with a checksum — and Apple silently keeps a half-uploaded asset if the
last step is skipped, which is why the commit is not optional.

    python3 scripts/upload-screenshots.py [--replace]
"""
from __future__ import annotations

import hashlib
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from asc import ASC, load_config  # noqa: E402

import requests  # noqa: E402

PANELS = pathlib.Path(__file__).resolve().parent.parent / "apps/ios/marketing/panels"
# The 6.9" slot (1320x2868). Apple's screenshot specification makes 6.5" the
# fallback — "required if screenshots for 6.9" display aren't provided" — and
# scales the 6.9" set down for every smaller iPhone, so this is the one to fill.
# There is no APP_IPHONE_69 in the API: 6.9" images go into APP_IPHONE_67.
DISPLAY_TYPE = "APP_IPHONE_67"
LOCALE = "en-US"


def main() -> int:
    replace = "--replace" in sys.argv
    cfg = load_config()
    asc = ASC(cfg)

    images = sorted(PANELS.glob("panel-*.png"))
    if not images:
        print(f"no panels in {PANELS} — run apps/ios/marketing/compose.py first")
        return 1

    versions = asc.get(f"/apps/{cfg['ASC_APP_ID']}/appStoreVersions", **{"limit": 10})["data"]
    editable = [
        v for v in versions
        if v["attributes"]["appStoreState"]
        in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")
    ]
    if not editable:
        print("no editable App Store version")
        return 1
    version = editable[0]
    print(f"version {version['attributes']['versionString']} ({version['attributes']['appStoreState']})")

    locs = asc.get(f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
    loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), locs[0] if locs else None)
    if not loc:
        print("no localization to attach screenshots to")
        return 1

    sets = asc.get(f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
    existing = next(
        (s for s in sets if s["attributes"]["screenshotDisplayType"] == DISPLAY_TYPE), None
    )

    if existing and replace:
        for shot in asc.get(f"/appScreenshotSets/{existing['id']}/appScreenshots")["data"]:
            asc.s.delete(f"https://api.appstoreconnect.apple.com/v1/appScreenshots/{shot['id']}")
        print("cleared existing screenshots")

    if existing:
        screenshot_set = existing
    else:
        screenshot_set = asc.post(
            "/appScreenshotSets",
            {
                "data": {
                    "type": "appScreenshotSets",
                    "attributes": {"screenshotDisplayType": DISPLAY_TYPE},
                    "relationships": {
                        "appStoreVersionLocalization": {
                            "data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}
                        }
                    },
                }
            },
        )["data"]
        print(f"created screenshot set {screenshot_set['id']}")

    already = len(asc.get(f"/appScreenshotSets/{screenshot_set['id']}/appScreenshots")["data"])
    if already and not replace:
        print(f"{already} screenshots already present — pass --replace to overwrite")
        return 0

    for image in images:
        data = image.read_bytes()

        reserved = asc.post(
            "/appScreenshots",
            {
                "data": {
                    "type": "appScreenshots",
                    "attributes": {"fileSize": len(data), "fileName": image.name},
                    "relationships": {
                        "appScreenshotSet": {
                            "data": {"type": "appScreenshotSets", "id": screenshot_set["id"]}
                        }
                    },
                }
            },
        )["data"]

        # Apple returns one or more byte ranges to PUT. Usually one, but the
        # contract allows chunking and honouring it costs nothing.
        for op in reserved["attributes"]["uploadOperations"]:
            chunk = data[op["offset"] : op["offset"] + op["length"]]
            headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
            response = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=120)
            response.raise_for_status()

        # Without this commit Apple keeps the asset in limbo: it exists, it is
        # not usable, and nothing in the UI explains why.
        asc.patch(
            f"/appScreenshots/{reserved['id']}",
            {
                "data": {
                    "type": "appScreenshots",
                    "id": reserved["id"],
                    "attributes": {
                        "uploaded": True,
                        "sourceFileChecksum": hashlib.md5(data).hexdigest(),
                    },
                }
            },
        )
        print(f"  uploaded {image.name} ({len(data) // 1024} KB)")

    final = asc.get(f"/appScreenshotSets/{screenshot_set['id']}/appScreenshots")["data"]
    print(f"\n{len(final)} screenshots on the {DISPLAY_TYPE} slot:")
    for s in final:
        a = s["attributes"]
        print(f"  {a.get('fileName')}  state={(a.get('assetDeliveryState') or {}).get('state')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
