"""Xcode Cloud's post-clone step (apps/ios/ci_scripts/ci_post_clone.sh)."""
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "apps/ios/ci_scripts/ci_post_clone.sh")
SECRETS = {"SUPABASE_HOST": "h.supabase.co", "SUPABASE_ANON_KEY": "anon",
           "DISPATCH_URL": "https://api.example.com"}


class PostCloneTests(unittest.TestCase):
    def setUp(self):
        self.repo = tempfile.mkdtemp()
        ios = os.path.join(self.repo, "apps/ios")
        os.makedirs(os.path.join(ios, "Crease.xcodeproj"))
        with open(os.path.join(ios, "project.yml"), "w") as f:
            f.write('settings:\n  base:\n    CURRENT_PROJECT_VERSION: "60"\n')
        with open(os.path.join(ios, "Crease.xcodeproj/project.pbxproj"), "w") as f:
            f.write("\t\t\t\tCURRENT_PROJECT_VERSION = 60;\n")
        self.secrets = os.path.join(ios, "Secrets.xcconfig")

    def tearDown(self):
        shutil.rmtree(self.repo)

    def run_script(self, **env):
        full = {"PATH": os.environ["PATH"], "CI_PRIMARY_REPOSITORY_PATH": self.repo, **env}
        return subprocess.run([SCRIPT], env=full, capture_output=True, text=True)

    def test_is_executable(self):
        # Xcode Cloud skips a ci script that is not executable.
        self.assertTrue(os.access(SCRIPT, os.X_OK))

    def test_writes_secrets_with_the_url_safe_for_xcconfig(self):
        r = self.run_script(**SECRETS, CI_TAG="tf-60")
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.secrets) as f:
            text = f.read()
        self.assertIn("SUPABASE_ANON_KEY = anon", text)
        # A bare // would start an xcconfig comment and truncate the URL.
        self.assertIn("DISPATCH_URL = https:$(SLASH)$(SLASH)api.example.com", text)

    def test_missing_secret_fails_the_build(self):
        env = dict(SECRETS)
        del env["SUPABASE_ANON_KEY"]
        self.assertNotEqual(self.run_script(**env).returncode, 0)

    def test_host_and_dispatch_url_default_when_unset(self):
        r = self.run_script(SUPABASE_ANON_KEY="anon")
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.secrets) as f:
            text = f.read()
        self.assertIn("SUPABASE_HOST = crease.supabase.co", text)
        self.assertIn("DISPATCH_URL = https:$(SLASH)$(SLASH)api.creasenyc.com", text)

    def test_xcode_cloud_counter_that_disagrees_with_the_tag_fails(self):
        r = self.run_script(**SECRETS, CI_TAG="tf-60", CI_BUILD_NUMBER="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("build 1, not 60", r.stderr)

    def test_xcode_cloud_counter_that_matches_passes(self):
        r = self.run_script(**SECRETS, CI_TAG="tf-60", CI_BUILD_NUMBER="60")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_tag_that_disagrees_with_the_build_number_fails(self):
        r = self.run_script(**SECRETS, CI_TAG="tf-61")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("build 60", r.stderr)


if __name__ == "__main__":
    unittest.main()
