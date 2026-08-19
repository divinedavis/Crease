#!/usr/bin/env python3
"""What counts as a visitor, tested against real log shapes.

On this site's first day, 62 "visitors" were counted and not one was a person.
Every rule in traffic.py exists because something got through, so every rule
gets a line here — a filter with no test is a filter that quietly stops working
the next time the log format changes.

    python3 -m growth.test_traffic
"""
import os
import tempfile
import unittest

from . import traffic

DAY = "2026-08-18"
IPHONE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 "
          "(KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1")
CHROME = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36")
OLD_CHROME = CHROME.replace("Chrome/151", "Chrome/94")


def line(ip, path, ua, host="creasenyc.com", status=200, ref="-", owner="-",
         ts="18/Aug/2026:14:03:11 +0000"):
    return (f'{host} {ip} - - [{ts}] "GET {path} HTTP/2.0" {status} 5657 '
            f'"{ref}" "{ua}" 0.031 0.030 "{owner}"\n')


class LogReadingTest(unittest.TestCase):
    def read(self, lines):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.writelines(lines)
        try:
            # No PTR lookups in a test: the budget is spent before the first
            # address, so an unknown one counts as a person, which is the
            # behaviour under a dead resolver too.
            # No reverse lookups in a test. The addresses below are RFC 5737
            # documentation ranges precisely so nothing here depends on what a
            # real /8 happens to have a PTR record for — the first version of
            # this file used 74.88.x, which resolves, and eight tests failed
            # for a reason that had nothing to do with what they were testing.
            old, traffic.PTR_LOOKUPS_PER_RUN = traffic.PTR_LOOKUPS_PER_RUN, 0
            try:
                rows, counters = traffic.read_day(DAY, path=path)
            finally:
                traffic.PTR_LOOKUPS_PER_RUN = old
            return rows, counters, traffic.visits(rows)
        finally:
            os.unlink(path)

    def test_a_person_counts_once_per_page(self):
        _, _, v = self.read([line("198.51.100.1.5", "/", IPHONE),
                             line("198.51.100.1.5", "/laundry-pickup/park-slope", IPHONE)])
        self.assertEqual(v["visitors"], 1)
        self.assertEqual(v["pageviews"], 2)

    def test_assets_are_not_page_views(self):
        _, c, v = self.read([line("198.51.100.1.5", "/", IPHONE),
                             line("198.51.100.1.5", "/_next/static/chunk.js", IPHONE),
                             line("198.51.100.1.5", "/assets/icon.svg", IPHONE),
                             line("198.51.100.1.5", "/favicon.ico", IPHONE)])
        self.assertEqual(v["pageviews"], 1)
        self.assertEqual(c["asset"], 3)

    def test_a_declared_bot_is_not_a_visitor(self):
        _, c, v = self.read([line("66.249.66.1", "/", "Googlebot/2.1 (+http://www.google.com/bot.html)")])
        self.assertEqual(v["visitors"], 0)
        self.assertEqual(c["bot_ua"], 1)

    def test_one_probe_condemns_everything_that_address_did(self):
        """A scanner that also fetches the home page is still a scanner."""
        _, c, v = self.read([line("203.0.113.9", "/.env", CHROME, status=404),
                             line("203.0.113.9", "/", CHROME)])
        self.assertEqual(v["visitors"], 0)
        # Both requests, not just the probe itself — the verdict is on the
        # address for the whole day, which is the point of the rule.
        self.assertEqual(c["probe"], 2)

    def test_a_datacenter_address_is_not_a_customer(self):
        _, c, v = self.read([line("34.82.1.1", "/", CHROME)])
        self.assertEqual(v["visitors"], 0)
        self.assertEqual(c["datacenter"], 1)

    def test_a_year_old_browser_is_not_a_browser(self):
        _, c, v = self.read([line("198.51.100.1.6", "/", OLD_CHROME)])
        self.assertEqual(v["visitors"], 0)
        self.assertEqual(c["stale_browser"], 1)

    def test_the_owner_cookie_wins_over_every_network(self):
        """The failure an address list can never cover: his phone changes IP."""
        _, c, v = self.read([line("198.51.100.1.7", "/", IPHONE, owner="1")])
        self.assertEqual(v["visitors"], 0)
        self.assertEqual(c["owner"], 1)

    def test_a_search_referrer_makes_a_visitor_organic(self):
        _, _, v = self.read([line("198.51.100.1.8", "/", IPHONE, ref="https://www.google.com/")])
        self.assertEqual(v["organic_visitors"], 1)
        _, _, v = self.read([line("198.51.100.1.9", "/", IPHONE, ref="https://news.ycombinator.com/")])
        self.assertEqual(v["organic_visitors"], 0)

    def test_another_site_on_the_same_box_is_ignored(self):
        _, _, v = self.read([line("198.51.100.2.1", "/", IPHONE, host="findacrib.com")])
        self.assertEqual(v["visitors"], 0)

    def test_the_old_usecreaseapp_host_still_counts(self):
        _, _, v = self.read([line("198.51.100.2.2", "/", IPHONE, host="usecreaseapp.com")])
        self.assertEqual(v["visitors"], 1)

    def test_another_day_is_ignored(self):
        _, _, v = self.read([line("198.51.100.2.3", "/", IPHONE, ts="17/Aug/2026:14:03:11 +0000")])
        self.assertEqual(v["visitors"], 0)

    def test_a_line_written_before_the_trailing_fields_existed_still_parses(self):
        """The owner cookie and $request_time were appended on different days."""
        old = (f'creasenyc.com 74.88.2.4 - - [18/Aug/2026:14:03:11 +0000] '
               f'"GET / HTTP/1.1" 200 5657 "-" "{IPHONE}"\n')
        _, _, v = self.read([old])
        self.assertEqual(v["visitors"], 1)

    def test_a_404_is_not_a_page_view(self):
        _, c, v = self.read([line("198.51.100.2.5", "/gone", IPHONE, status=404)])
        self.assertEqual(v["visitors"], 0)
        self.assertEqual(c["error"], 1)

    def test_paths_are_grouped_without_their_query_string(self):
        _, _, v = self.read([line("198.51.100.2.6", "/?owner=0", IPHONE)])
        self.assertIn("/", v["by_path"])


if __name__ == "__main__":
    unittest.main()
