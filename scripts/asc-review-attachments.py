#!/usr/bin/env python3
"""Attach screenshots to the App Store review detail, through the API.

App Review's "we were unable to verify" rejections are answered by showing
them the screen, not by describing it. Notes are prose a reviewer reads on a
different device than the one in front of them; an attachment is the thing
itself, and it rides along with the submission rather than sitting in a
message thread.

    python3 scripts/asc-review-attachments.py            # what is attached now
    python3 scripts/asc-review-attachments.py apply      # upload review/attachment.png
    python3 scripts/asc-review-attachments.py clear      # remove it

Apple takes exactly ONE attachment per version (a second is refused with
STATE_ERROR), so anything worth showing has to be one image. The numbered PNGs
beside it in apps/ios/marketing/review are the screens it was composed from —
keep them, they are what a recomposed sheet gets built out of next time.

The upload is Apple's three-step dance: reserve (which hands back the exact
PUT it wants, headers and all), send the bytes, then declare it uploaded with
the file's MD5 as the receipt. A reservation left undeclared is an attachment
that shows as nothing at all, so the PATCH is not optional.
"""
from __future__ import annotations

import hashlib
import pathlib
import sys

import requests

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from asc import ASC, load_config  # noqa: E402

SHOTS = pathlib.Path(__file__).resolve().parent.parent / "apps/ios/marketing/review"
SHEET = SHOTS / "attachment.png"


def review_detail_id(asc: ASC, app_id: str) -> str:
    """The review detail of the version that can still be edited."""
    versions = asc.get(f"/apps/{app_id}/appStoreVersions", limit=10)["data"]
    editable = [
        v for v in versions
        if v["attributes"]["appStoreState"] in
        ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")
    ]
    if not editable:
        raise SystemExit("no editable App Store version — nothing to attach to")
    version = editable[0]
    detail = asc.get(f"/appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
    if not detail:
        raise SystemExit("this version has no review detail yet — run asc-metadata.py first")
    return detail["id"]


def existing(asc: ASC, detail_id: str) -> list[dict]:
    return asc.get(f"/appStoreReviewDetails/{detail_id}/appStoreReviewAttachments")["data"]


def upload(asc: ASC, detail_id: str, path: pathlib.Path) -> None:
    payload = path.read_bytes()
    reserved = asc.post(
        "/appStoreReviewAttachments",
        {
            "data": {
                "type": "appStoreReviewAttachments",
                "attributes": {"fileName": path.name, "fileSize": len(payload)},
                "relationships": {
                    "appStoreReviewDetail": {
                        "data": {"type": "appStoreReviewDetails", "id": detail_id}
                    }
                },
            }
        },
    )["data"]

    for op in reserved["attributes"]["uploadOperations"]:
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        chunk = payload[op["offset"]:op["offset"] + op["length"]]
        r = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=120)
        r.raise_for_status()

    asc.patch(
        f"/appStoreReviewAttachments/{reserved['id']}",
        {
            "data": {
                "type": "appStoreReviewAttachments",
                "id": reserved["id"],
                "attributes": {
                    "uploaded": True,
                    "sourceFileChecksum": hashlib.md5(payload).hexdigest(),
                },
            }
        },
    )
    print(f"  uploaded {path.name} ({len(payload):,} bytes)")


def main() -> None:
    cfg = load_config()
    asc = ASC(cfg)
    detail_id = review_detail_id(asc, cfg["ASC_APP_ID"])
    cmd = sys.argv[1] if len(sys.argv) > 1 else "show"

    if cmd == "show":
        for a in existing(asc, detail_id):
            at = a["attributes"]
            print(f"  {at.get('fileName')}  {at.get('assetDeliveryState', {}).get('state')}")
        return

    # Both remaining commands clear first, and for `apply` it is mandatory
    # rather than tidy: with one slot filled, Apple refuses the upload outright.
    for a in existing(asc, detail_id):
        asc.s.delete(f"https://api.appstoreconnect.apple.com/v1/appStoreReviewAttachments/{a['id']}",
                     timeout=30).raise_for_status()
        print(f"  removed {a['attributes'].get('fileName')}")
    if cmd == "clear":
        return
    if cmd != "apply":
        raise SystemExit(__doc__)

    if not SHEET.exists():
        raise SystemExit(f"nothing to attach — expected {SHEET}")
    upload(asc, detail_id, SHEET)


if __name__ == "__main__":
    main()
