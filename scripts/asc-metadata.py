#!/usr/bin/env python3
"""Write the App Store listing for Crease through the API.

Everything App Store Connect will accept over its API is here, so the listing
is a file in the repo rather than a memory of which boxes were ticked in a web
form: categories, subtitle, description, keywords, URLs, copyright, the age
rating questionnaire, the review contact and demo account, and the price.

Idempotent — every call is a PATCH or an upsert, so re-running after an edit
just re-states the listing.

    python3 scripts/asc-metadata.py            # apply
    python3 scripts/asc-metadata.py --show     # print what is there now

Two things Apple does NOT expose over the API and which therefore have to be
done in the browser:

  * App Privacy (the data-collection questionnaire). There is no
    appDataUsages resource on v1 — every path 404s with PATH_ERROR.
  * Submitting the version for review.

The demo-account password is read from the login keychain, never stored here:

    security add-generic-password -a "$USER" -s crease-test-password -w '...'
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from asc import ASC, load_config  # noqa: E402

API = "https://api.appstoreconnect.apple.com/v1"

SUBTITLE = "Laundry pickup and delivery"          # <= 30 characters
KEYWORDS = ("laundry,dry cleaning,wash and fold,pickup,delivery,"
            "brooklyn,cleaners,garment,fold,courier")   # <= 100 characters
PROMO = ("Leave the bag at your door in Brooklyn. A courier takes it to a real "
         "neighborhood cleaner and brings it back folded. No counter, no closing time.")
SITE = "https://creasenyc.com/"
PRIVACY = "https://creasenyc.com/privacy.html"
COPYRIGHT = "2026 Divine Davis"
PRIMARY_CATEGORY = "LIFESTYLE"
SECONDARY_CATEGORY = "SHOPPING"
DEMO_ACCOUNT = "testcustomer@crease.local"

# The review contact is a real person's phone number and this repo is public,
# so it lives in the gitignored asc-config.env alongside the API key ids:
#     ASC_CONTACT_FIRST_NAME / ASC_CONTACT_LAST_NAME
#     ASC_CONTACT_PHONE      / ASC_CONTACT_EMAIL

DESCRIPTION = """Crease collects your laundry and dry cleaning from your door in Brooklyn, takes it to a neighborhood cleaner, and brings it back clean.

HOW IT WORKS
1. Book a pickup. Say what is in the bag and choose a window.
2. A courier collects it and takes it to the cleaner.
3. The shop counts, weighs and cleans it, and a courier brings it back to you.

WHAT IT COSTS
You see an estimate before the bag leaves the house, built from what you tell us is in it. Nobody can price a bag without opening it, so the shop's count at intake settles the bill. Your card is authorized for the estimate plus a small allowance and charged only for what the shop actually finds. If the real total lands above that allowance, the order stops and asks you to approve it first. Nothing is charged without your say-so.

FOLLOW BOTH LEGS
A dry cleaning order is two deliveries with a gap in the middle, and the app shows the whole arc: collected, at the cleaner, ready, and on its way back. The days at the shop are part of the picture rather than a silence you have to interpret.

WHERE WE COLLECT
Within three miles of Fulton Cleaners at 909 Fulton Street: Clinton Hill, Fort Greene, Prospect Heights, Bedford-Stuyvesant, Park Slope, Downtown Brooklyn, DUMBO, Boerum Hill, Crown Heights, Gowanus, Carroll Gardens, Cobble Hill, Brooklyn Heights and more. Type your address and the app tells you either way before you book.

SIGNING IN
Apple, Google, or an email address and password. Nothing to confirm in your inbox — you are in as soon as you sign up.

Wash and fold is priced by the pound with a shop minimum; dry cleaning is priced per garment. Both are the shop's own prices, not a markup.
"""

REVIEW_NOTES = """WHAT THE APP DOES
Crease is a laundry and dry-cleaning pickup and delivery service in Brooklyn, NY. A courier collects a bag from the customer's door, takes it to a partner cleaner, and a second courier returns it a couple of days later.

DEMO ACCOUNT
Sign in with "Continue with email" on the first screen and use the account above. (Apple and Google sign-in also work, but the email account is the one seeded with data.)

SERVICE AREA — IMPORTANT FOR TESTING
Pickups are only offered within three miles of our partner cleaner at 909 Fulton Street, Brooklyn, NY 11238. An address outside that radius is correctly refused, so please use a Brooklyn address when testing, for example:
    100 Clinton Avenue, Brooklyn, NY 11205
Typing an out-of-area address will show a "not yet in your area" message; that is expected behaviour, not a bug.

PAYMENTS
Stripe is running in test mode for review. Use card 4242 4242 4242 4242, any future expiry date, any CVC, any ZIP. No real money moves. The card is authorized (not charged) at booking, because the final price depends on the shop's count when the bag is opened; the customer approves anything above the authorized amount before it is charged.

WHY THE ORDER SITS "AT THE CLEANER"
An order is two separate deliveries with a two-day gap between them, so a freshly booked order will not complete during a short review session. The order list and detail screens show the full journey at every stage.

CONTACT
Any question at all: the email and phone number above.
"""

# Nothing in a laundry app is age-gated. Note the types: Apple's newer
# questionnaire fields (advertising, messagingAndChat, userGeneratedContent,
# healthOrWellnessTopics, ageAssurance, parentalControls) are BOOLEANs, while
# the older content fields are three-value enums — sending "NONE" for a boolean
# field fails with ENTITY_ERROR.ATTRIBUTE.TYPE, and omitting any of them fails
# with ATTRIBUTE.REQUIRED. All of them have to go in one PATCH.
AGE_RATING = {
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE",
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "advertising": False,
    "ageAssurance": False,
    "gambling": False,
    "healthOrWellnessTopics": False,
    "lootBox": False,
    "messagingAndChat": False,
    "parentalControls": False,
    "unrestrictedWebAccess": False,
    "userGeneratedContent": False,
    "ageRatingOverride": "NONE",
}

EDITABLE_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED",
                   "REJECTED", "METADATA_REJECTED")


def demo_password() -> str:
    """The test account's password, from the keychain.

    Never a literal here: this repo is public, and the account is a real login
    against the production Supabase project.
    """
    out = subprocess.run(
        ["security", "find-generic-password", "-a", pathlib.Path.home().name,
         "-s", "crease-test-password", "-w"],
        capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("no keychain item 'crease-test-password' — see the module docstring")
    return out.stdout.strip()


def resolve(asc: ASC, app_id: str) -> dict:
    info = asc.get(f"/apps/{app_id}/appInfos")["data"][0]
    versions = asc.get(f"/apps/{app_id}/appStoreVersions", limit=10)["data"]
    editable = [v for v in versions if v["attributes"]["appStoreState"] in EDITABLE_STATES]
    if not editable:
        raise SystemExit("no editable App Store version — every version is already submitted")
    version = editable[0]
    return {
        "info": info["id"],
        "info_loc": asc.get(f"/appInfos/{info['id']}/appInfoLocalizations")["data"][0]["id"],
        "version": version["id"],
        "version_string": version["attributes"]["versionString"],
        "version_loc": asc.get(
            f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"][0]["id"],
    }


def apply(asc: ASC, cfg: dict) -> None:
    app_id = cfg["ASC_APP_ID"]
    ids = resolve(asc, app_id)
    print(f"==> version {ids['version_string']}")

    asc.patch(f"/apps/{app_id}", {"data": {
        "type": "apps", "id": app_id,
        "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})
    print("    content rights")

    asc.patch(f"/appInfos/{ids['info']}", {"data": {
        "type": "appInfos", "id": ids["info"], "relationships": {
            "primaryCategory": {"data": {"type": "appCategories", "id": PRIMARY_CATEGORY}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": SECONDARY_CATEGORY}}}}})
    print(f"    categories {PRIMARY_CATEGORY} / {SECONDARY_CATEGORY}")

    asc.patch(f"/appInfoLocalizations/{ids['info_loc']}", {"data": {
        "type": "appInfoLocalizations", "id": ids["info_loc"],
        "attributes": {"subtitle": SUBTITLE, "privacyPolicyUrl": PRIVACY}}})
    print("    subtitle + privacy policy URL")

    asc.patch(f"/appStoreVersionLocalizations/{ids['version_loc']}", {"data": {
        "type": "appStoreVersionLocalizations", "id": ids["version_loc"],
        "attributes": {"description": DESCRIPTION, "keywords": KEYWORDS,
                       "promotionalText": PROMO, "supportUrl": SITE, "marketingUrl": SITE}}})
    print("    description, keywords, URLs")

    asc.patch(f"/appStoreVersions/{ids['version']}", {"data": {
        "type": "appStoreVersions", "id": ids["version"],
        "attributes": {"copyright": COPYRIGHT, "usesIdfa": False}}})
    print("    copyright, IDFA declaration")

    asc.patch(f"/ageRatingDeclarations/{ids['info']}", {"data": {
        "type": "ageRatingDeclarations", "id": ids["info"], "attributes": AGE_RATING}})
    print("    age rating (4+)")

    # Upsert: the review detail is created with the version and PATCHed after.
    detail = asc.get(f"/appStoreVersions/{ids['version']}/appStoreReviewDetail").get("data")
    missing = [k for k in ("ASC_CONTACT_FIRST_NAME", "ASC_CONTACT_LAST_NAME",
                           "ASC_CONTACT_PHONE", "ASC_CONTACT_EMAIL") if not cfg.get(k)]
    if missing:
        raise SystemExit("asc-config.env is missing: " + ", ".join(missing))
    attributes = {
        "contactFirstName": cfg["ASC_CONTACT_FIRST_NAME"],
        "contactLastName": cfg["ASC_CONTACT_LAST_NAME"],
        "contactPhone": cfg["ASC_CONTACT_PHONE"],
        "contactEmail": cfg["ASC_CONTACT_EMAIL"],
        "demoAccountName": DEMO_ACCOUNT, "demoAccountPassword": demo_password(),
        "demoAccountRequired": True, "notes": REVIEW_NOTES,
    }
    if detail:
        asc.patch(f"/appStoreReviewDetails/{detail['id']}", {"data": {
            "type": "appStoreReviewDetails", "id": detail["id"], "attributes": attributes}})
    else:
        asc.post("/appStoreReviewDetails", {"data": {
            "type": "appStoreReviewDetails", "attributes": attributes,
            "relationships": {"appStoreVersion": {
                "data": {"type": "appStoreVersions", "id": ids["version"]}}}}})
    print("    review contact + demo account")

    # Free, with the USA as the base territory. A price schedule already set is
    # left alone: replacing it would reset any scheduled price change.
    existing = asc.s.get(f"{API}/apps/{app_id}/appPriceSchedule", timeout=30)
    if existing.status_code == 200 and existing.json().get("data"):
        print("    price schedule already set — left alone")
        return
    points = asc.get(f"/apps/{app_id}/appPricePoints",
                     **{"filter[territory]": "USA", "limit": 200})["data"]
    free = next(p for p in points if float(p["attributes"]["customerPrice"]) == 0.0)
    asc.post("/appPriceSchedules", {
        "data": {"type": "appPriceSchedules", "relationships": {
            "app": {"data": {"type": "apps", "id": app_id}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
        "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {
                          "data": {"type": "appPricePoints", "id": free["id"]}}}}]})
    print("    price: free")


def show(asc: ASC, cfg: dict) -> None:
    app_id = cfg["ASC_APP_ID"]
    ids = resolve(asc, app_id)
    loc = asc.get(f"/appStoreVersionLocalizations/{ids['version_loc']}")["data"]["attributes"]
    info_loc = asc.get(f"/appInfoLocalizations/{ids['info_loc']}")["data"]["attributes"]
    version = asc.get(f"/appStoreVersions/{ids['version']}")["data"]["attributes"]
    detail = asc.get(f"/appStoreVersions/{ids['version']}/appStoreReviewDetail").get("data")
    build = asc.get(f"/appStoreVersions/{ids['version']}/build").get("data")
    print(f"version {version['versionString']}  {version['appStoreState']}")
    print(f"  subtitle     {info_loc['subtitle']}")
    print(f"  description  {len(loc['description'] or '')} chars")
    print(f"  keywords     {loc['keywords']}")
    print(f"  support      {loc['supportUrl']}")
    print(f"  privacy      {info_loc['privacyPolicyUrl']}")
    print(f"  copyright    {version['copyright']}")
    print(f"  build        {build['attributes']['version'] if build else '(none attached)'}")
    print(f"  review info  {'set' if detail else 'MISSING'}")


def main() -> None:
    cfg = load_config()
    asc = ASC(cfg)
    (show if "--show" in sys.argv else apply)(asc, cfg)


if __name__ == "__main__":
    main()
