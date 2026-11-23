"""Static checks on migration 0055 (shop sign-up by invite link), no database.

The live behaviour is proven by scripts/invite-check.mjs in the journey suite.
These guard the shape that makes it safe, so a later edit that drops one of
them fails in seconds on a laptop instead of in production:

  - the two new tables are closed to anon/authenticated (RLS on, grants revoked)
  - every new function is SECURITY DEFINER with a pinned search_path
  - the founder-only functions check is_crease_admin() before anything else
  - is_crease_admin() itself is not callable over the API (0057)
  - a claimed shop is created inactive, and only approve_shop switches it on
  - the invite commission cannot go below the card-fee floor 0038 enforces
"""
import re
import unittest
from pathlib import Path

MIGRATIONS = Path(__file__).resolve().parent.parent / "supabase" / "migrations"
SQL = re.sub(r"--[^\n]*", "", (MIGRATIONS / "0055_shop_invites.sql").read_text())
FUNCTIONS = {
    m.group(1): m.group(0)
    for m in re.finditer(
        r"create\s+or\s+replace\s+function\s+public\.(\w+)\s*\(.*?\$\$.*?\$\$;", SQL, re.I | re.S
    )
}
ADMIN_ONLY = ["create_shop_invite", "list_shop_invites", "approve_shop"]


class ShopInviteMigration(unittest.TestCase):
    def test_all_functions_found(self):
        self.assertEqual(
            sorted(FUNCTIONS),
            sorted(ADMIN_ONLY + ["is_crease_admin", "peek_shop_invite", "claim_shop_invite"]),
        )

    def test_tables_are_closed_to_clients(self):
        for table in ("crease_admins", "shop_invites"):
            self.assertRegex(SQL, rf"alter table public\.{table} enable row level security", table)
            self.assertRegex(SQL, rf"revoke all on public\.{table} from public, anon, authenticated", table)
            self.assertNotRegex(SQL, rf"grant [^;]* on public\.{table} to [^;]*(anon|authenticated)", table)

    def test_functions_are_definer_with_pinned_search_path(self):
        for name, body in FUNCTIONS.items():
            self.assertRegex(body, r"security definer", name)
            self.assertRegex(body, r"set search_path = public, pg_temp", name)

    def test_founder_functions_check_admin_first(self):
        for name in ADMIN_ONLY:
            body = FUNCTIONS[name]
            begin = body.lower().index("begin")
            first_statement = body[begin:begin + 120]
            self.assertIn("if not public.is_crease_admin() then", first_statement, name)

    def test_execute_grants(self):
        def granted(fn):
            return re.findall(rf"grant execute on function public\.{fn}\([^)]*\) to ([^;]+);", SQL)
        self.assertEqual(granted("peek_shop_invite"), ["anon, authenticated"])
        self.assertEqual(granted("claim_shop_invite"), ["authenticated"])
        for name in ADMIN_ONLY:
            self.assertEqual(granted(name), ["authenticated"], name)
            self.assertRegex(SQL, rf"revoke all on function public\.{name}\([^)]*\) from public, anon;", name)

    def test_the_admin_check_is_a_helper_not_an_endpoint(self):
        # 0057: no signed-in user can call it over the API; the founder
        # functions call it as their owner. Nothing after 0057 may grant it back.
        later = sorted(p for p in MIGRATIONS.glob("*.sql") if p.name >= "0057")
        self.assertEqual(later[0].name, "0057_is_crease_admin_not_an_rpc.sql")
        sql = re.sub(r"--[^\n]*", "", later[0].read_text())
        self.assertRegex(sql, r"revoke all on function public\.is_crease_admin\(\) from public, anon, authenticated;")
        for path in later:
            text = re.sub(r"--[^\n]*", "", path.read_text())
            for grantees in re.findall(r"grant execute on function public\.is_crease_admin\(\) to ([^;]+);", text):
                self.assertEqual(grantees.strip(), "service_role", path.name)

    def test_claim_makes_an_inactive_shop_owned_by_the_caller(self):
        body = FUNCTIONS["claim_shop_invite"]
        self.assertRegex(body, r"v_invite\.commission_bps, false, null\)")
        self.assertRegex(body, r"values \(v_id, v_uid, 'owner'\)")
        self.assertRegex(body, r"for update")
        self.assertIn("auth.uid()", body)

    def test_only_approve_shop_sets_active(self):
        for name, body in FUNCTIONS.items():
            sets_active = re.search(r"set\s+active\s*=\s*true", body, re.I)
            self.assertEqual(bool(sets_active), name == "approve_shop", name)

    def test_commission_floor_matches_0038(self):
        floor = re.search(
            r"commission_bps\s*>=\s*(\d+)",
            (MIGRATIONS / "0038_commission_covers_the_card.sql").read_text(),
        )
        self.assertIsNotNone(floor)
        self.assertRegex(SQL, rf"default {floor.group(1)} check \(commission_bps between {floor.group(1)} and")


if __name__ == "__main__":
    unittest.main()
