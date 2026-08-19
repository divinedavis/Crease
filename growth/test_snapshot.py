#!/usr/bin/env python3
"""The assertion that stands between a public repository and a customer's address.

snapshot.json is committed and pushed to a PUBLIC repo so the cloud review
agent can read it. The tables it summarises are lists of where people live. If
this test ever fails, do not relax the assertion — find what put a person into
an aggregate.

    python3 -m growth.test_snapshot
"""
import unittest

from . import snapshot


class PiiAssertionTest(unittest.TestCase):
    def test_a_clean_document_passes(self):
        self.assertTrue(snapshot._assert_no_pii(
            {"visitors": 12, "queries": ["laundry pickup park slope"],
             "note": "coverage is 40% and rank is unknown"}))

    def test_the_owners_own_address_is_allowed(self):
        """It is already on the website; refusing it would refuse every run."""
        self.assertTrue(snapshot._assert_no_pii({"contact": "divinejdavis@gmail.com"}))

    def test_a_customer_email_is_refused(self):
        with self.assertRaises(RuntimeError):
            snapshot._assert_no_pii({"leads": ["someone@example.com"]})

    def test_a_phone_number_is_refused(self):
        for number in ("718-555-0142", "(718) 555-0142", "+1 718 555 0142", "7185550142"):
            with self.assertRaises(RuntimeError, msg=number):
                snapshot._assert_no_pii({"shop": number})

    def test_a_street_address_is_refused(self):
        with self.assertRaises(RuntimeError):
            snapshot._assert_no_pii({"pickup": "141 Front St, Brooklyn"})
        with self.assertRaises(RuntimeError):
            snapshot._assert_no_pii({"pickup": "909 Fulton Street"})

    def test_a_neighborhood_name_is_not_an_address(self):
        snapshot._assert_no_pii({"areas": ["Clinton Hill", "Bedford-Stuyvesant", "DUMBO"]})

    def test_the_real_snapshot_passes(self):
        """Whatever the ledger currently holds must be publishable."""
        snapshot._assert_no_pii(snapshot.build())


if __name__ == "__main__":
    unittest.main()
