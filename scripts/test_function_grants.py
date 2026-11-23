"""Static checks on migration 0058 (function grants nobody uses), no database.

The live proof is the journey suite (rls-check.mjs, invite-check.mjs) and the
weekly Supabase security check. These keep the shape from drifting:

  - no trigger function is reachable by a client role
  - the two that had no pinned search_path have one
  - the staff checks are open to signed-in users only
  - no later migration hands any of it back
"""
import re
import unittest
from pathlib import Path

MIGRATIONS = Path(__file__).resolve().parent.parent / "supabase" / "migrations"
NAME = "0058_trigger_functions_are_not_endpoints.sql"
TRIGGER_FUNCTIONS = [
    "touch_updated_at", "clear_courier_pii_on_terminal", "cap_open_drafts",
    "forbid_customer_status_change", "handle_new_user", "validate_order_item",
]
STAFF_CHECKS = ["is_cleaner_staff", "is_cleaner_admin"]


def sql_of(path):
    return re.sub(r"--[^\n]*", "", path.read_text())


class FunctionGrants(unittest.TestCase):
    SQL = sql_of(MIGRATIONS / NAME)

    def test_trigger_functions_are_closed_to_clients(self):
        for fn in TRIGGER_FUNCTIONS:
            self.assertRegex(
                self.SQL, rf"revoke all on function public\.{fn}\(\) from public, anon, authenticated;", fn)

    def test_search_path_is_pinned(self):
        for fn in ("touch_updated_at", "clear_courier_pii_on_terminal"):
            self.assertRegex(self.SQL, rf"alter function public\.{fn}\(\) set search_path = public, pg_temp;", fn)

    def test_staff_checks_are_for_signed_in_users_only(self):
        for fn in STAFF_CHECKS:
            self.assertRegex(self.SQL, rf"revoke all on function public\.{fn}\(uuid\) from public, anon;", fn)
            self.assertRegex(
                self.SQL, rf"grant execute on function public\.{fn}\(uuid\) to authenticated, service_role;", fn)

    def test_nothing_later_hands_it_back(self):
        for path in sorted(p for p in MIGRATIONS.glob("*.sql") if p.name > NAME):
            text = sql_of(path)
            for fn in TRIGGER_FUNCTIONS:
                grants = re.findall(rf"grant [^;]*on function public\.{fn}\([^)]*\) to ([^;]+);", text, re.I)
                for grantees in grants:
                    self.assertNotRegex(grantees, r"\b(public|anon|authenticated)\b", f"{path.name}: {fn}")
                # Recreating a function resets its grants to PUBLIC: it must be revoked again.
                if re.search(rf"create\s+(or\s+replace\s+)?function\s+public\.{fn}\s*\(", text, re.I):
                    self.assertRegex(
                        text, rf"revoke all on function public\.{fn}\(\) from public, anon, authenticated;",
                        f"{path.name} recreates {fn} without closing it again")
            for fn in STAFF_CHECKS:
                for grantees in re.findall(rf"grant [^;]*on function public\.{fn}\([^)]*\) to ([^;]+);", text, re.I):
                    self.assertNotRegex(grantees, r"\b(public|anon)\b", f"{path.name}: {fn}")


if __name__ == "__main__":
    unittest.main()
