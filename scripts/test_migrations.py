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


if __name__ == "__main__":
    unittest.main()
