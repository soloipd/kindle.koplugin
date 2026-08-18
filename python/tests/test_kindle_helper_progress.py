import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "python" / "kindle_helper.py"


class KindleHelperProgressTests(unittest.TestCase):
    def test_cli_enqueues_and_lists_root_private_progress_state(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state = root / "state"
            plugin = root / "plugin"
            watcher = plugin / "bin" / "watch-close-progress"
            watcher.parent.mkdir(parents=True)
            watcher.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
            watcher.chmod(0o755)
            command = [
                sys.executable, str(HELPER), "enqueue-close-progress",
                "--asin", "B007N6JEII",
                "--sequence", "1760000000000001",
                "--native-path-hex",
                "/mnt/us/documents/Test_B007N6JEII.kfx".encode().hex(),
                "--epub-path-hex",
                "/mnt/us/koreader/cache/kindle.koplugin/test.epub".encode().hex(),
                "--xpointer-hex",
                "/body/DocFragment/body/p/text().42".encode().hex(),
                "--koreader-percent", "54.25",
                "--status-hex", "reading".encode().hex(),
                "--closed-at", "1760000000",
                "--open-native-long", "AAAAAAAAAAA1",
                "--open-native-short", "100",
                "--open-local-long", "AAAAAAAAAAA2",
                "--open-local-short", "200",
                "--state-dir", str(state),
                "--plugin-dir", str(plugin),
            ]
            queued = subprocess.run(
                command, check=False, capture_output=True, text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            self.assertEqual(0, queued.returncode, queued.stderr)
            self.assertTrue(json.loads(queued.stdout)["queued"])
            request_path = state / "progress-outbox" / "B007N6JEII"
            self.assertTrue(request_path.is_file())
            request_text = request_path.read_text(encoding="ascii")
            self.assertIn("queue_version=2\n", request_text)
            self.assertIn("open_native_long=AAAAAAAAAAA1\n", request_text)
            self.assertIn("open_local_short=200\n", request_text)

            listed = subprocess.run(
                [sys.executable, str(HELPER), "close-progress-receipts",
                 "--state-dir", str(state)],
                check=False, capture_output=True, text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            self.assertEqual(0, listed.returncode, listed.stderr)
            self.assertEqual([], json.loads(listed.stdout)["receipts"])


if __name__ == "__main__":
    unittest.main()
