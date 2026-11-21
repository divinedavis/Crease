"""Deploy scripts run under `set -o pipefail`, so `x | head -N` can abort them.

`head` exits after N lines; the writer then dies of SIGPIPE, pipefail turns
that into a failure, and `set -e` stops the script. On 2026-11-21 that killed
deploy/rollback.sh between restoring files and restarting services. Use
`sed -n '1,Np'`, which reads all of its input. (`head -n -N`, which also reads
everything, is fine.)
"""
import glob
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EARLY_HEAD = re.compile(r"\|\s*head\s+(-n\s+)?-?\d+(?!\S)")


class DeployPipeTests(unittest.TestCase):
    def test_no_deploy_script_pipes_into_an_early_exiting_head(self):
        scripts = sorted(glob.glob(os.path.join(ROOT, "deploy", "*.sh")))
        self.assertGreater(len(scripts), 3)
        for path in scripts:
            for n, line in enumerate(open(path), 1):
                for m in EARLY_HEAD.finditer(line):
                    if re.search(r"head\s+-n\s+-\d+", m.group(0)):
                        continue  # drops the last N lines: reads everything
                    with self.subTest(script=os.path.basename(path), line=n):
                        self.fail(f"`{m.group(0).strip()}` can SIGPIPE under pipefail; use sed -n")


if __name__ == "__main__":
    unittest.main()
