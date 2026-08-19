#!/usr/bin/env python3
"""What the guide validator must refuse.

These are not hypotheticals. Every case here is something a model does when
asked to write a page about a local service: it rounds a price, invents a
cheaper minimum, wanders into a URL-shaped slug, writes two paragraphs and
calls it a page, or mentions itself. Any one of them reaches a public page the
morning it happens, unread, and stays there.

    python3 -m growth.test_writer
"""
import copy
import unittest

from . import writer

GOOD = {
    "slug": "how-much-wash-and-fold-costs-in-brooklyn",
    "title": "How much wash and fold costs in Brooklyn",
    "description": "Wash and fold in Brooklyn is priced by the pound. Here is what a bag "
                   "actually comes to, and what the courier fee adds on top of it.",
    "intro": "Wash and fold is $2.00 a pound with a $20 minimum. A two-week bag for one "
             "person is usually 12 to 18 pounds, so most single bags land between $24 and $36.",
    "sections": [
        {"heading": "Priced by the pound",
         "body": ["You pay for what the bag weighs on the shop's scale, not an estimate."]},
        {"heading": "The courier fee",
         "body": ["The courier fee is $29.95 for a round trip, or $16.95 for one leg."]},
        {"heading": "When the total changes",
         "body": ["If the bag comes to more than the estimate, nothing is charged until "
                  "you approve it."]},
    ],
    "faq": [{"q": "Is there a minimum?", "a": "Yes, the minimum is $20, about 10 pounds."},
            {"q": "Do you do dry cleaning?", "a": "Not yet — wash and fold only."}],
    "areas": ["clinton-hill", "fort-greene"],
}


def mutated(**changes):
    d = copy.deepcopy(GOOD)
    d.update(changes)
    return d


class ValidatorTest(unittest.TestCase):
    def test_accepts_a_correct_draft(self):
        g = writer.validate(copy.deepcopy(GOOD), "how much does wash and fold cost")
        self.assertEqual(g["slug"], GOOD["slug"])
        self.assertEqual(len(g["sections"]), 3)
        self.assertEqual(g["areas"], ["clinton-hill", "fort-greene"])

    def test_derived_totals_are_not_prices_we_claim(self):
        """"$24 to $36" is arithmetic a reader wants, not a rate we charge.

        The first version of this check refused any dollar figure that was not
        one of ours, which refused every genuinely useful page.
        """
        writer.validate(mutated(intro="A 12 pound bag comes to about $24, plus the trip."),
                        "q")

    def test_refuses_a_wrong_rate_per_pound(self):
        with self.assertRaises(writer.Rejected):
            writer.validate(mutated(intro="Wash and fold is $1.25 a pound."), "q")

    def test_refuses_a_wrong_minimum(self):
        d = copy.deepcopy(GOOD)
        d["faq"][0] = {"q": "Is there a minimum?", "a": "Yes, the minimum is $10."}
        with self.assertRaises(writer.Rejected):
            writer.validate(d, "q")

    def test_refuses_a_wrong_courier_fee(self):
        d = copy.deepcopy(GOOD)
        d["sections"][1] = {"heading": "Fee",
                            "body": ["The courier fee is $9.99 for a round trip."]}
        with self.assertRaises(writer.Rejected):
            writer.validate(d, "q")

    def test_refuses_a_slug_that_is_a_path(self):
        for bad in ("guides/../etc", "a", "Has Spaces", "trailing-", "../../etc/passwd"):
            with self.assertRaises(writer.Rejected, msg=bad):
                writer.validate(mutated(slug=bad), "q")

    def test_refuses_a_thin_page(self):
        with self.assertRaises(writer.Rejected):
            writer.validate(mutated(sections=GOOD["sections"][:1]), "q")

    def test_refuses_a_page_that_talks_about_itself(self):
        d = copy.deepcopy(GOOD)
        d["faq"].append({"q": "who wrote this", "a": "As an AI, I did."})
        with self.assertRaises(writer.Rejected):
            writer.validate(d, "q")

    def test_refuses_an_overlong_title(self):
        with self.assertRaises(writer.Rejected):
            writer.validate(mutated(title="x" * 200), "q")

    def test_repairs_unknown_areas_rather_than_refusing(self):
        """The mesh matters; the model's opinion about it does not."""
        g = writer.validate(mutated(areas=["mars", "atlantis"]), "q")
        self.assertTrue(g["areas"])
        self.assertTrue(set(g["areas"]) <= set(writer.area_slugs()))


if __name__ == "__main__":
    unittest.main()
