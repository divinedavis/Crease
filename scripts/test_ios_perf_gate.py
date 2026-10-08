"""The iOS perf gate's pass/fail rule (scripts/ios-perf-gate.py)."""
import importlib.util
import os
import unittest

_spec = importlib.util.spec_from_file_location(
    "ios_perf_gate", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ios-perf-gate.py"))
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)


class RegressedTests(unittest.TestCase):
    def test_a_doubled_time_fails(self):
        self.assertTrue(gate.regressed(3.6, 1.7, "s"))

    def test_a_wobble_in_time_passes(self):
        self.assertFalse(gate.regressed(2.2, 1.7, "s"))

    def test_a_sub_megabyte_memory_jump_passes(self):
        # The 2026-10-08 case: 0.82 MB against a 0.41 MB baseline.
        self.assertFalse(gate.regressed(819.2, 409.6, "kB"))

    def test_a_real_memory_regression_still_fails(self):
        self.assertTrue(gate.regressed(5000, 409.6, "kB"))
        self.assertTrue(gate.regressed(150_000, 91_326, "kB"))

    def test_large_memory_within_tolerance_passes(self):
        self.assertFalse(gate.regressed(101_000, 91_326, "kB"))

    def test_bigger_is_better_metrics_fail_on_a_halving(self):
        self.assertTrue(gate.regressed(40, 100, "fps", smaller=False))
        self.assertFalse(gate.regressed(80, 100, "fps", smaller=False))


if __name__ == "__main__":
    unittest.main()
