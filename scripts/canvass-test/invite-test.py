"""Canvass shop sign-up test.

The canvass page is where the founder stands in front of a shop that just said
yes. It has to mint a sign-up link for that shop (once, not one per tap), show
it with a QR, list the shops that used a link and are waiting, and approve one.
It must also stay exactly the old page for anyone who is not an admin. Drives
the real page against the stubbed Supabase with the 0055 functions faked.

    python3 scripts/canvass-test/invite-test.py
"""
import tempfile, threading, http.server, functools, pathlib, shutil, sys
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(tempfile.mkdtemp(prefix="invite-test-"))
html = (ROOT / "growth/prospects/index.html").read_text() \
    .replace("__SUPABASE_URL__", "https://stub.local").replace("__SUPABASE_ANON_KEY__", "stub-anon")
(HERE / "index.html").write_text(html)

base_stub = (pathlib.Path(__file__).parent / "stub-supabase.js").read_text()
admin_stub = base_stub + """
(function () {
  const server = window.__server;
  server.calls = [];
  // One shop already signed up and waiting; the canvassed shops have none.
  server.invites = [
    { id: 'i-wait', code: 'AAAAAAAAAAAA', label: 'Joseph Laundromat', prospect_id: null,
      created_at: '2026-11-20T00:00:00Z', expires_at: '2099-01-01T00:00:00Z',
      claimed_at: '2026-11-21T00:00:00Z', cleaner_id: 'c-joseph', shop_name: 'Joseph Laundromat',
      shop_address: '1 Nostrand Ave, Brooklyn, NY 11216', shop_phone: '+17185550100',
      active: false, approved_at: null, payouts_enabled: false,
      price_cents_per_lb: 125, minimum_lbs: 10 },
  ];
  server.rpc = {
    list_shop_invites: () => ({ data: server.invites.map((i) => ({ ...i })), error: null }),
    create_shop_invite: ({ p_label, p_prospect }) => {
      server.calls.push(['create', p_label, p_prospect]);
      const open = server.invites.find((i) => i.prospect_id === p_prospect && !i.claimed_at);
      if (open) return { data: [{ id: open.id, code: open.code, expires_at: open.expires_at }], error: null };
      const inv = { id: 'i-new', code: 'B1B2C3D4E5F6', label: p_label, prospect_id: p_prospect,
        created_at: new Date().toISOString(), expires_at: '2099-01-01T00:00:00Z',
        claimed_at: null, cleaner_id: null, active: null };
      server.invites.push(inv);
      return { data: [{ id: inv.id, code: inv.code, expires_at: inv.expires_at }], error: null };
    },
    approve_shop: ({ p_cleaner }) => {
      server.calls.push(['approve', p_cleaner]);
      const inv = server.invites.find((i) => i.cleaner_id === p_cleaner);
      if (!inv) return { data: false, error: null };
      inv.active = true;
      return { data: true, error: null };
    },
  };
})();
"""

fails = []
def check(name, cond, extra=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else f"   <- {extra}"))
    if not cond: fails.append(name)

def serve(stub, port):
    d = pathlib.Path(tempfile.mkdtemp(prefix="invite-test-site-"))
    (d / "index.html").write_text(html)
    (d / "supabase.js").write_text(stub)
    shutil.copy(ROOT / "growth/prospects/session-cookie.js", d / "session-cookie.js")
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(d))
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{port}/index.html"

ADMIN_URL = serve(admin_stub, 8736)
PLAIN_URL = serve(base_stub, 8737)

with sync_playwright() as p:
    b = p.chromium.launch()

    # --- not an admin: nothing new appears ---------------------------------
    pg = b.new_page()
    errors = []
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.goto(PLAIN_URL)
    pg.click("#google")
    pg.wait_for_selector("#list")
    check("non-admin sees no approvals card", pg.query_selector("#approvals") is None)
    pg.fill("#q", "Yes")   # search opens every neighbourhood
    pg.click(".shop[data-id='aaa'] [data-expand]")
    check("non-admin editor has no sign-up button", pg.query_selector("[data-invite]") is None)
    check("non-admin page threw nothing", not errors, errors)
    pg.close()

    # --- admin ---------------------------------------------------------------
    ctx = b.new_context()
    ctx.grant_permissions(["clipboard-read", "clipboard-write"])
    pg = ctx.new_page()
    errors = []
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.goto(ADMIN_URL)
    pg.click("#google")
    pg.wait_for_selector("#list")

    card = pg.inner_text("#approvals") if pg.query_selector("#approvals") else ""
    check("a waiting shop is listed at the top", "1 shop waiting for your approval" in card, card)
    check("waiting shop shows its price and payout state",
          "$1.25/lb, 10 lb minimum" in card and "payouts not set up yet" in card, card)

    pg.fill("#q", "Yes")   # search opens every neighbourhood
    pg.click(".shop[data-id='aaa'] [data-expand]")
    pg.click("[data-invite]")
    pg.wait_for_selector("[data-link]")
    link = pg.inner_text("[data-link]").strip()
    check("the link is this origin's /join/<code>", link == "http://127.0.0.1:8736/join/B1B2C3D4E5F6", link)
    calls = pg.evaluate("window.__server.calls")
    check("invite minted for this canvassed shop", calls == [["create", "Yes Cleaners", "aaa"]], calls)

    pg.click("[data-copy]")
    check("copy puts the link on the clipboard",
          pg.evaluate("navigator.clipboard.readText()") == link)
    pg.click("[data-qr]")
    src = pg.get_attribute(".invite img", "src")
    check("QR points at the portal's qr.svg for that code", src == "/join/B1B2C3D4E5F6/qr.svg", src)

    # The stub's store lives in the page, so a reload would forget the invite;
    # collapsing and reopening re-renders from the loaded list instead.
    pg.click(".shop[data-id='aaa'] [data-expand]")
    pg.click(".shop[data-id='aaa'] [data-expand]")
    check("reopening the shop shows the same link, not a new button",
          pg.query_selector("[data-invite]") is None and "B1B2C3D4E5F6" in pg.inner_text("[data-link]"))

    pg.click("[data-approve='c-joseph']")
    pg.wait_for_function("!document.querySelector('#approvals')")
    calls = pg.evaluate("window.__server.calls")
    check("approve calls approve_shop for that shop", ["approve", "c-joseph"] in calls, calls)
    check("approved shop leaves the waiting list", pg.query_selector("#approvals") is None)
    check("admin page threw nothing", not errors, errors)
    b.close()

print(f"\n{len(fails)} failed" if fails else "\nall passed")
sys.exit(1 if fails else 0)
