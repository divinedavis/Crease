"""Production journeys must only ever book orders for the App Review account.

Only a review account's orders are held to the simulated courier. On
2026-11-21 e2e-cancel took "the first address in the table" and its dispatch
went to Shipday for real. Every journey that builds an order now takes its
address from reviewAddress() or from the signed-in test account.
"""
import glob
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JOURNEYS = sorted(glob.glob(os.path.join(ROOT, "scripts", "e2e*.mjs")))

# An addresses query is safe when it is scoped to a user id; an unscoped one
# can return any customer's row.
ADDRESS_QUERY = re.compile(r"from\('addresses'\)(?P<chain>(?:\s*\.\s*\w+\([^;]*?\))*)", re.S)


class JourneyAddressTests(unittest.TestCase):
    def test_there_are_journeys_to_check(self):
        self.assertGreater(len(JOURNEYS), 3)

    def test_no_journey_reads_an_address_it_did_not_scope_to_a_user(self):
        for path in JOURNEYS:
            src = open(path).read()
            for m in ADDRESS_QUERY.finditer(src):
                chain = m.group("chain")
                # A row the journey already holds (by id) or is creating is fine too.
                scoped = any(k in chain for k in (".eq('user_id'", ".in('user_id'", ".insert(", ".eq('id'"))
                with self.subTest(journey=os.path.basename(path), query=chain[:80]):
                    self.assertTrue(scoped, "unscoped addresses query: use reviewAddress(db)")

    def test_review_address_never_falls_back(self):
        src = open(os.path.join(ROOT, "scripts", "lib", "client.mjs")).read()
        body = src[src.index("export async function reviewAddress"):]
        self.assertIn(".eq('is_review_account', true)", body)
        self.assertIn(".in('user_id', ids)", body)
        self.assertIn("throw new Error('no review account", body)


if __name__ == "__main__":
    unittest.main()
