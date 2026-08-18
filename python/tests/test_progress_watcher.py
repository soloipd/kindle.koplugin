import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
WATCHER = ROOT / "bin" / "watch-close-progress"


class ProgressWatcherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.plugin = self.root / "plugin"
        self.bin = self.plugin / "bin"
        self.bin.mkdir(parents=True)
        shutil.copy2(WATCHER, self.bin / "watch-close-progress")
        (self.bin / "watch-close-progress").chmod(0o755)
        self.state = self.root / "state"
        self.outbox = self.state / "progress-outbox"
        self.outbox.mkdir(parents=True)
        self.lock_root = self.root / "locks"
        self.lock_root.mkdir()

    def run_watcher(self):
        environment = os.environ.copy()
        environment.update({
            "KINDLE_PLUGIN_DIR": str(self.plugin),
            "KINDLE_PROGRESS_STATE_DIR": str(self.state),
            "KINDLE_PROGRESS_LOCK_DIR": str(self.lock_root),
            "KINDLE_PROGRESS_MAX_SWEEPS": "3",
            "KINDLE_PROGRESS_HELPER_RUNNER": "/bin/sh",
        })
        return subprocess.run(
            ["/bin/sh", str(self.bin / "watch-close-progress")],
            check=False, capture_output=True, text=True,
            timeout=15, env=environment,
        )

    def write_helper(self, body):
        helper = self.plugin / "kindle-helper"
        helper.write_text("#!/bin/sh\nset -u\n" + body, encoding="utf-8")
        helper.chmod(0o755)

    def test_retries_three_times_then_leaves_transient_request(self):
        attempts = self.root / "attempts"
        self.write_helper(
            'printf "x\\n" >>"$WATCH_ATTEMPTS"\nexit 75\n')
        request = self.outbox / "B007N6JEII"
        request.write_text("retained\n", encoding="ascii")
        os.environ["WATCH_ATTEMPTS"] = str(attempts)
        self.addCleanup(os.environ.pop, "WATCH_ATTEMPTS", None)

        result = self.run_watcher()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(request.exists())
        self.assertEqual(3, len(attempts.read_text().splitlines()))
        self.assertFalse(
            (self.lock_root / "kindle-close-progress-watcher.lock").exists())

    def test_drains_request_and_releases_single_flight_lock(self):
        self.write_helper('rm -f "$3"\nexit 0\n')
        request = self.outbox / "B007N6JEII"
        request.write_text("consumed\n", encoding="ascii")

        result = self.run_watcher()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(request.exists())
        self.assertFalse(
            (self.lock_root / "kindle-close-progress-watcher.lock").exists())

    def test_reclaims_dead_owner_lock_without_following_symlinks(self):
        stale = self.lock_root / "kindle-close-progress-watcher.lock"
        stale.mkdir()
        (stale / "pid").write_text("999999\n", encoding="ascii")
        self.write_helper('rm -f "$3"\nexit 0\n')
        request = self.outbox / "B007N6JEII"
        request.write_text("consumed\n", encoding="ascii")

        result = self.run_watcher()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(request.exists())
        self.assertFalse(stale.exists())


if __name__ == "__main__":
    unittest.main()
