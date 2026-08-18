"""Canvass borough-scoping test.

The canvass list was Brooklyn-only for its whole life, so every count and every
neighbourhood group silently assumed one market. Once the roadmap opens a
second one, mixing them is a real hazard: a shop thirty minutes away rendered
next to the one you are standing in front of. This drives the real page against
a stubbed Supabase holding two boroughs.

    python3 scripts/canvass-test/borough-test.py
"""
import tempfile, threading, http.server, functools, pathlib, shutil, sys
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(tempfile.mkdtemp(prefix="borough-test-"))
html = (ROOT / "growth/prospects/index.html").read_text() \
    .replace("__SUPABASE_URL__", "https://stub.local").replace("__SUPABASE_ANON_KEY__", "stub-anon")
(HERE / "index.html").write_text(html)

# The shared stub is Brooklyn-only on purpose (the autosave test depends on its
# exact fixture); a second market is appended here rather than added there.
stub = (pathlib.Path(__file__).parent / "stub-supabase.js").read_text() + """
window.__server.rows[0].borough = 'Brooklyn';
window.__server.rows[1].borough = 'Brooklyn';
window.__server.rows.push(
  { id: 'ccc', osm_id: '3', kind: 'dry_cleaner', name: 'Chelsea Cleaners', address: '1 W 20th',
    zip: '10011', phone: null, lat: 40.7, lng: -74.0, neighborhood: 'Chelsea', borough: 'Manhattan',
    visited: false, visited_at: null, outcome: null, notes: null, full_service: null,
    own_app: null, cash_only: null, created_at: null, updated_at: null },
  // No borough at all — a row seeded before migration 0036. Must read Brooklyn.
  { id: 'ddd', osm_id: '4', kind: 'dry_cleaner', name: 'Legacy Cleaners', address: '9 Nostrand',
    zip: '11205', phone: null, lat: 40.6, lng: -73.9, neighborhood: 'Bed-Stuy',
    visited: false, visited_at: null, outcome: null, notes: null, full_service: null,
    own_app: null, cash_only: null, created_at: null, updated_at: null });
"""
(HERE / "supabase.js").write_text(stub)

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(HERE))
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8734), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = "http://127.0.0.1:8734/index.html"

fails = []
def check(name, cond, extra=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else f"   <- {extra}"))
    if not cond: fails.append(name)

names = lambda pg: pg.eval_on_selector_all(".shop .name", "els => els.map(e => e.childNodes[0].textContent.trim())")

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    errors = []
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.goto(URL)
    pg.fill("#email", "c@example.com"); pg.fill("#pw", "good"); pg.click("button.primary")
    pg.wait_for_selector("#list")

    check("a second market brings out the borough segment", pg.is_visible("#boroseg"))
    check("segment offers both markets",
          pg.eval_on_selector_all("#boroseg button", "els => els.map(e => e.textContent.trim())")
          == ["Brooklyn", "Manhattan"])
    check("a market is pinned rather than left mixed",
          pg.eval_on_selector_all("#boroseg button.on", "els => els.map(e => e.textContent.trim())") == ["Brooklyn"])

    shown = names(pg)
    check("Brooklyn list excludes the Manhattan shop", "Chelsea Cleaners" not in shown, shown)
    check("a null-borough row counts as Brooklyn", "Legacy Cleaners" in shown, shown)
    check("kind counts are the market's, not the table's",
          "Dry cleaners · 3" in pg.inner_text("#kindseg"), pg.inner_text("#kindseg"))
    check("header names the market", pg.inner_text("h1").strip() == "Brooklyn canvass", pg.inner_text("h1"))

    # Search must not tunnel out of the market: a same-name shop in another
    # borough is not the shop in front of you.
    pg.fill("#q", "Cleaners")
    check("search stays inside the market", "Chelsea Cleaners" not in names(pg), names(pg))
    pg.fill("#q", "")

    pg.click("#boroseg button:has-text('Manhattan')")
    pg.wait_for_selector("#list")
    check("switching market swaps the list", names(pg) == ["Chelsea Cleaners"], names(pg))
    check("header follows the market", pg.inner_text("h1").strip() == "Manhattan canvass")
    check("counts follow the market", "Dry cleaners · 1" in pg.inner_text("#kindseg"), pg.inner_text("#kindseg"))

    # The chosen market is the one thing on this page worth remembering across
    # a reload: you do not re-pick your borough every time the phone sleeps.
    pg.reload(); pg.wait_for_selector("#list")
    check("market survives a reload", pg.inner_text("h1").strip() == "Manhattan canvass", pg.inner_text("h1"))

    check("the roadmap is one tap away", pg.is_visible("a[href='roadmap.html']"))
    check("no page errors", not errors, errors[:3])
    b.close()

srv.shutdown()
print()
print("FAILED: " + ", ".join(fails) if fails else "all checks passed")
sys.exit(1 if fails else 0)
