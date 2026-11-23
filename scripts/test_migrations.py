"""Static checks on supabase/migrations (no database needed).

Guards against the bug fixed in 0054: in plpgsql, `DELETE ... RETURNING x INTO v`
raises "query returned more than one row" once the statement touches two rows.
purge_delivery_events() was written that way, passed while nothing was old
enough to purge, then failed every week and silently stopped the retention sweep.
"""
import re
import unittest
from pathlib import Path

MIGRATIONS = Path(__file__).resolve().parent.parent / "supabase" / "migrations"
FUNCTION = re.compile(
    r"create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?(\w+)\s*\(.*?\$(\w*)\$(.*?)\$\2\$",
    re.I | re.S,
)
# A DELETE that captures RETURNING into a variable; fine only for a single-row delete by key.
DELETE_RETURNING_INTO = re.compile(r"\bdelete\s+from\b[^;]*?\breturning\b[^;]*?\binto\b[^;]*;", re.I | re.S)
SINGLE_ROW = re.compile(r"\bwhere\b[^;]*\b(id|\w+_id)\s*=\s*", re.I | re.S)


def latest_function_bodies() -> dict[str, tuple[str, str]]:
    """{function name: (migration file, body)} for the definition that is live (the last one)."""
    latest: dict[str, tuple[str, str]] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        sql = re.sub(r"--[^\n]*", "", path.read_text())
        for match in FUNCTION.finditer(sql):
            latest[match.group(1).lower()] = (path.name, match.group(3))
    return latest


class Migrations(unittest.TestCase):
    def test_finds_functions(self):
        self.assertIn("purge_delivery_events", latest_function_bodies())

    def test_purge_delivery_events_counts_with_row_count(self):
        name, body = latest_function_bodies()["purge_delivery_events"]
        self.assertNotRegex(body, r"(?is)returning\b.*\binto\b", name)
        self.assertRegex(body, r"(?i)get\s+diagnostics\s+\w+\s*=\s*row_count")

    def test_no_multi_row_delete_returning_into(self):
        bad = []
        for fn, (name, body) in latest_function_bodies().items():
            for stmt in DELETE_RETURNING_INTO.findall(body):
                if not SINGLE_ROW.search(stmt):
                    bad.append(f"{fn} ({name}): {' '.join(stmt.split())[:120]}")
        self.assertEqual(bad, [], "DELETE ... RETURNING ... INTO raises on a second row; use GET DIAGNOSTICS")

    def test_the_rule_catches_the_original_bug(self):
        old = "begin delete from public.delivery_events where received_at < now() returning 1 into n; end;"
        self.assertTrue(DELETE_RETURNING_INTO.search(old))
        self.assertFalse(SINGLE_ROW.search(DELETE_RETURNING_INTO.search(old).group(0)))




class PlaceholderPointMigration(unittest.TestCase):
    """0056: the app's Brooklyn stand-in point is never stored as a door."""

    SQL = re.sub(r"--[^\n]*", "", (MIGRATIONS / "0056_addresses_drop_placeholder_point.sql").read_text())

    def test_trigger_runs_before_writes_to_the_point(self):
        self.assertRegex(self.SQL, r"before insert or update of lat, lng on public\.addresses")

    def test_stand_in_becomes_null_not_an_error(self):
        self.assertRegex(self.SQL, r"abs\(new\.lat - 40\.7178\) < 0\.00005 and abs\(new\.lng \+ 73\.9569\) < 0\.00005")
        self.assertRegex(self.SQL, r"new\.lat := null;\s*new\.lng := null;")
        self.assertNotRegex(self.SQL, r"raise exception")

    def test_matches_the_ios_stand_in(self):
        swift = (MIGRATIONS.parent.parent / "apps/ios/Crease/Features/Pickup/AddressSearch.swift").read_text()
        self.assertIn("CLLocationCoordinate2D(latitude: 40.7178, longitude: -73.9569)", swift)

    def test_function_is_not_callable_by_clients(self):
        self.assertRegex(self.SQL, r"revoke all on function public\.addresses_drop_placeholder_point\(\) from public, anon, authenticated")


if __name__ == "__main__":
    unittest.main()
