"""Canvass autosave regression test.

The canvass tool is the only place field work is recorded, and its writes were
losing data whenever the access token expired mid-session (Postgres answered
42501 and the note went nowhere). This drives the real page in a browser
against a stubbed Supabase — no project credentials, no network — and asserts
the queue holds every edit through a dead session, a reload, a dead signal,
and a policy refusal.

    pip3 install playwright && python3 -m playwright install chromium
    python3 scripts/canvass-test/autosave-test.py
"""
import json, sys, tempfile, threading, http.server, functools, pathlib, shutil
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "growth/prospects/index.html"

HERE = pathlib.Path(tempfile.mkdtemp(prefix="canvass-test-"))
html = SRC.read_text().replace("__SUPABASE_URL__", "https://stub.local").replace("__SUPABASE_ANON_KEY__", "stub-anon")
(HERE / "index.html").write_text(html)
shutil.copy(pathlib.Path(__file__).parent / "stub-supabase.js", HERE / "supabase.js")

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(HERE))
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8731), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()

fails = []
def check(name, cond, extra=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else f"   <- {extra}"))
    if not cond: fails.append(name)

with sync_playwright() as p:
    b = p.chromium.launch()
    page = b.new_page()
    page.on("console", lambda m: print("  [console]", m.type, m.text) if m.type == "error" else None)
    page.goto("http://127.0.0.1:8731/index.html")

    # sign in
    page.fill("#email", "canvasser@example.com")
    page.fill("#pw", "good")
    page.click("#login button")
    page.wait_for_selector(".shop", state="attached")
    page.evaluate("() => document.querySelectorAll('details.hood').forEach(d => d.open = true)")
    check("list renders after sign-in", page.locator(".shop").count() == 2)

    # open Yes Cleaners
    page.locator('.shop[data-id="aaa"] [data-expand]').click()
    page.wait_for_selector('.shop[data-id="aaa"] [data-notes]', state="attached")

    # --- happy path -------------------------------------------------------
    page.fill('.shop[data-id="aaa"] [data-notes]', "Spoke to owner")
    page.wait_for_timeout(1200)
    row = page.evaluate("() => window.__server.rows.find(r => r.id === 'aaa')")
    check("online note reaches the server", row["notes"] == "Spoke to owner", row)
    check("queue empties after a good save", page.evaluate("() => localStorage.canvassPending") in (None, "{}"), page.evaluate("() => localStorage.canvassPending"))
    check("row shows Saved", "Saved" in page.locator('.shop[data-id="aaa"] [data-save]').inner_text())

    # --- session dies mid-canvass (the reported bug) ----------------------
    page.evaluate("() => window.__expire()")
    page.fill('.shop[data-id="aaa"] [data-notes]', "Declined because they don't trust someones belongings being delivered.")
    page.wait_for_timeout(1200)
    pend = json.loads(page.evaluate("() => localStorage.canvassPending || '{}'"))
    check("edit is queued when signed out", pend.get("aaa", {}).get("notes", "").startswith("Declined because"), pend)
    check("no raw permission error shown",
          "permission denied" not in page.locator('.shop[data-id="aaa"] [data-save]').inner_text(),
          page.locator('.shop[data-id="aaa"] [data-save]').inner_text())
    check("sync bar offers re-auth", page.locator("#resync").is_visible())
    srow = page.evaluate("() => window.__server.rows.find(r => r.id === 'aaa')")
    check("server unchanged while signed out", srow["notes"] == "Spoke to owner", srow)

    # tap an outcome while signed out too
    page.locator('.shop[data-id="aaa"] [data-outseg] [data-out="declined"]').click()
    page.wait_for_timeout(300)
    pend = json.loads(page.evaluate("() => localStorage.canvassPending || '{}'"))
    check("outcome tap queues too", pend.get("aaa", {}).get("outcome") == "declined", pend)
    check("outcome chip shows immediately", page.locator('.shop[data-id="aaa"] .chip.declined').count() == 1)

    # --- reload with a dead session: nothing lost -------------------------
    page.reload()
    page.wait_for_selector("#login")   # signed out -> login screen
    page.fill("#email", "canvasser@example.com")
    page.fill("#pw", "good")
    page.click("#login button")
    page.wait_for_selector(".shop", state="attached")
    page.evaluate("() => document.querySelectorAll('details.hood').forEach(d => d.open = true)")
    page.wait_for_timeout(1200)
    srow = page.evaluate("() => window.__server.rows.find(r => r.id === 'aaa')")
    check("queued note survives reload and syncs", srow["notes"].startswith("Declined because"), srow)
    check("queued outcome syncs", srow["outcome"] == "declined", srow)
    check("queue drained", page.evaluate("() => localStorage.canvassPending") in (None, "{}"), page.evaluate("() => localStorage.canvassPending"))
    check("sync bar clears", page.locator("#syncbar").inner_text().strip() == "", page.locator("#syncbar").inner_text())

    # --- offline (no signal between shops) --------------------------------
    page.locator('.shop[data-id="aaa"] [data-expand]').click()
    page.wait_for_selector('.shop[data-id="aaa"] [data-notes]', state="attached")
    page.evaluate("() => { window.__server.offline = true; }")
    page.fill('.shop[data-id="aaa"] [data-notes]', "Go back Sunday")
    page.wait_for_timeout(1200)
    pend = json.loads(page.evaluate("() => localStorage.canvassPending || '{}'"))
    check("offline edit is queued", pend.get("aaa", {}).get("notes") == "Go back Sunday", pend)
    page.evaluate("() => { window.__server.offline = false; window.dispatchEvent(new Event('online')); }")
    page.wait_for_timeout(800)
    srow = page.evaluate("() => window.__server.rows.find(r => r.id === 'aaa')")
    check("queue drains when signal returns", srow["notes"] == "Go back Sunday", srow)

    # --- in-place re-auth (no page loss) ----------------------------------
    page.evaluate("() => window.__expire()")
    page.fill('.shop[data-id="aaa"] [data-notes]', "Cash only, owner is Maria")
    page.wait_for_timeout(1200)
    check("list still on screen after session death", page.locator(".shop").count() == 2)
    page.fill("#repw", "good")
    page.click("#resync button")
    page.wait_for_timeout(1000)
    srow = page.evaluate("() => window.__server.rows.find(r => r.id === 'aaa')")
    check("in-place re-auth drains the queue", srow["notes"] == "Cash only, owner is Maria", srow)

    # writes never lost a keystroke: final server state matches the textarea
    check("textarea matches server", page.locator('.shop[data-id="aaa"] [data-notes]').input_value() == srow["notes"])

    # --- policy refuses the write (wrong account): must not vanish silently ---
    page.evaluate("() => { window.__server.rlsDenies = true; }")
    page.fill('.shop[data-id="aaa"] [data-notes]', "Should not disappear quietly")
    page.wait_for_timeout(1200)
    page.evaluate("() => document.querySelectorAll('details.hood').forEach(d => d.open = true)")
    txt = page.locator('.shop[data-id="aaa"] [data-save]').inner_text()
    check("RLS refusal is surfaced, not silent", "cannot edit" in txt, txt)
    check("refused edit is not left pretending to be queued",
          page.evaluate("() => localStorage.canvassPending") in (None, "{}"),
          page.evaluate("() => localStorage.canvassPending"))

    b.close()

srv.shutdown()
print("\n" + ("ALL PASS" if not fails else f"{len(fails)} FAILED: {fails}"))
sys.exit(1 if fails else 0)