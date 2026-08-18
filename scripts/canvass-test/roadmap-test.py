"""Expansion-roadmap regression test.

The roadmap is only worth having if its numbers are the real ones, so the
things worth pinning are the ones that would quietly lie: which market counts
as current, which shops land in which borough, and whether a row seeded before
the borough column existed still counts as Brooklyn. Drives the real page in a
browser against a stubbed Supabase — no project credentials, no network.

    pip3 install playwright && python3 -m playwright install chromium
    python3 scripts/canvass-test/roadmap-test.py
"""
import tempfile, threading, http.server, functools, pathlib, shutil, sys
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "growth/prospects/roadmap.html"

HERE = pathlib.Path(tempfile.mkdtemp(prefix="roadmap-test-"))
html = SRC.read_text().replace("__SUPABASE_URL__", "https://stub.local").replace("__SUPABASE_ANON_KEY__", "stub-anon")
(HERE / "roadmap.html").write_text(html)
shutil.copy(pathlib.Path(__file__).parent / "stub-roadmap.js", HERE / "supabase.js")

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(HERE))
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8732), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = "http://127.0.0.1:8732/roadmap.html"

fails = []
def check(name, cond, extra=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else f"   <- {extra}"))
    if not cond: fails.append(name)

def sign_in(page):
    page.fill("#email", "divinejdavis@gmail.com")
    page.fill("#pw", "good")
    page.click("button.primary")
    page.wait_for_selector(".phases .phase")

# Metrics for one phase card, by its heading.
def phase_metrics(page, borough):
    return page.evaluate("""(b) => {
      const card = [...document.querySelectorAll('.phase')]
        .find(p => p.querySelector('h2').textContent.trim().startsWith(b));
      if (!card) return null;
      const m = {};
      for (const el of card.querySelectorAll('.metric')) {
        m[el.querySelector('.l').textContent.trim()] = el.querySelector('.n').textContent.trim();
      }
      return { metrics: m, chip: card.querySelector('.chip').textContent.trim(),
               current: card.classList.contains('current'),
               gates: [...card.querySelectorAll('.gates li')].map(li => ({
                 met: li.classList.contains('met'),
                 what: li.querySelector('.what').textContent.trim(),
                 why: li.querySelector('.why').textContent.trim() })) };
    }""", borough)

with sync_playwright() as p:
    b = p.chromium.launch()
    page = b.new_page()
    errors = []
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(URL)

    # --- signed out ------------------------------------------------------
    check("signed out shows a sign-in form", page.is_visible("#login"))
    check("signed out links back to the canvass", page.is_visible("a[href='./']"))

    sign_in(page)

    # --- the plan --------------------------------------------------------
    boroughs = page.eval_on_selector_all(".phase h2", "els => els.map(e => e.textContent.trim().split(' ')[0])")
    check("all five markets are on the page", len(page.query_selector_all(".phase")) == 5, boroughs)
    order = page.eval_on_selector_all(".phase h2", "els => els.map(e => e.childNodes[0].textContent.trim())")
    check("markets are in plan order",
          order == ["Brooklyn", "Manhattan", "Queens", "Staten Island", "New Jersey"], order)
    check("timeline draws one bar per market", len(page.query_selector_all(".tl-bar")) == 5)
    check("timeline marks today", page.is_visible(".tl-today"))

    # --- Brooklyn: the current phase, counted live -----------------------
    bk = phase_metrics(page, "Brooklyn")
    check("Brooklyn is the current phase", bk["current"], bk["chip"])
    check("hero names the current phase", page.inner_text(".hero .big").strip() == "Brooklyn")
    # 6 rows: five explicit Brooklyn plus the pre-0036 row with a null borough.
    check("a null borough still counts as Brooklyn", bk["metrics"]["On the list"] == "6", bk["metrics"])
    check("Brooklyn visited count", bk["metrics"]["Visited"] == "4", bk["metrics"])
    check("Brooklyn interested count", bk["metrics"]["Interested"] == "1", bk["metrics"])
    check("Brooklyn follow-up count", bk["metrics"]["Follow up"] == "1", bk["metrics"])
    # c1 (11217) and c6 (no ZIP, city Brooklyn); c5 is inactive.
    check("Brooklyn partners: active shops only, ZIP or city",
          bk["metrics"]["Partners live"] == "2", bk["metrics"])

    # --- borough placement by ZIP ---------------------------------------
    mn = phase_metrics(page, "Manhattan")
    qn = phase_metrics(page, "Queens")
    si = phase_metrics(page, "Staten Island")
    check("10001 lands in Manhattan", mn["metrics"]["Partners live"] == "1", mn["metrics"])
    check("11101 lands in Queens", qn["metrics"]["Partners live"] == "1", qn["metrics"])
    check("11550 (Nassau) lands in no borough", si["metrics"]["Partners live"] == "0", si["metrics"])
    check("Queens list is seeded from its own rows", qn["metrics"]["On the list"] == "1", qn["metrics"])
    check("Manhattan has nothing seeded yet", mn["metrics"]["On the list"] == "0", mn["metrics"])

    # --- gates are observed, never assumed -------------------------------
    g = {x["what"]: x for x in bk["gates"]}
    check("Brooklyn seeded gate met", g["Prospect list seeded"]["met"])
    check("Brooklyn canvass gate not met at 4/6", not g["Every shop canvassed"]["met"],
          g["Every shop canvassed"]["why"])
    check("Brooklyn yes gate met", g["A shop said yes"]["met"])
    check("Brooklyn partner gate names the shops", "Fulton Cleaners" in g["A partner is live"]["why"],
          g["A partner is live"]["why"])
    mg = {x["what"]: x for x in mn["gates"]}
    check("an unseeded market says so", not mg["Prospect list seeded"]["met"]
          and "no shops seeded" in mg["Prospect list seeded"]["why"])
    check("an unseeded market cannot have finished its canvass", not mg["Every shop canvassed"]["met"],
          mg["Every shop canvassed"]["why"])
    # A shop can sign before its borough's list is built — the gate reports
    # that rather than waiting for the phase to open.
    check("a partner ahead of the phase still counts", mg["A partner is live"]["met"],
          mg["A partner is live"]["why"])

    # --- a partner-list failure must not take the page down --------------
    page.evaluate("() => localStorage.setItem('stub-fail-cleaners', '1')")
    page.reload()
    page.wait_for_selector(".phases .phase")
    check("canvass numbers survive a partner-list failure",
          phase_metrics(page, "Brooklyn")["metrics"]["On the list"] == "6")
    check("the partner failure is stated, not hidden", page.is_visible(".notice.warn"))

    check("no console or page errors", not errors, errors[:3])
    b.close()

srv.shutdown()
print()
print("FAILED: " + ", ".join(fails) if fails else "all checks passed")
sys.exit(1 if fails else 0)
