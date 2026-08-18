import os
import stat
import sys
import tempfile
import unittest
from unittest import mock


PYTHON_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PYTHON_DIR not in sys.path:
    sys.path.insert(0, PYTHON_DIR)

import progress_outbox as outbox


ASIN = "B007N6JEII"
LOCAL = {"long": "AAAAAAAAAAA2", "pid": 200}
PREVIOUS = {"long": "AAAAAAAAAAA1", "pid": 100}
NATIVE = {"long": "AAAAAAAAAAA3", "pid": 300, "percent": 41.0}


class ProgressOutboxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = os.path.join(self.temp.name, "state")
        self.debug = os.path.join(self.temp.name, "debug.log")
        self.plugin = os.path.join(self.temp.name, "plugin")
        os.makedirs(os.path.join(self.plugin, "bin"))

    def request(self, sequence="1760000000000001", previous=None,
                percent=54.25, session_baseline=None):
        return {
            "asin": ASIN,
            "sequence": sequence,
            "native_path": "/mnt/us/documents/Test_B007N6JEII.kfx",
            "epub_path": "/mnt/us/koreader/cache/kindle.koplugin/test.epub",
            "xpointer": "/body/DocFragment/body/p/text().42",
            "koreader_percent": percent,
            "status": "reading",
            "closed_at": 1760000000,
            "previous": previous,
            "session_baseline": session_baseline,
        }

    def enqueue(self, **kwargs):
        request = self.request(**kwargs)
        outbox.enqueue(request, state_dir=self.state, launch=False)
        return os.path.join(self.state, "progress-outbox", ASIN)

    def test_enqueue_is_private_checksummed_and_latest_wins(self):
        first_session = {"native": PREVIOUS, "local": PREVIOUS}
        latest_session = {"native": NATIVE, "local": LOCAL}
        path = self.enqueue(
            sequence="1760000000000001",
            session_baseline=first_session)
        first = outbox.parse_request(path)
        self.enqueue(
            sequence="1760000000000002", percent=55.0,
            session_baseline=latest_session)
        latest = outbox.parse_request(path)

        self.assertEqual("1760000000000001", first["sequence"])
        self.assertEqual("1760000000000002", latest["sequence"])
        self.assertEqual(55.0, latest["koreader_percent"])
        self.assertEqual(
            NATIVE["long"], latest["session_baseline"]["native"]["long"])
        self.assertEqual(
            LOCAL["pid"], latest["session_baseline"]["local"]["pid"])
        self.assertEqual(0o600, stat.S_IMODE(os.stat(path).st_mode))
        self.assertEqual(
            0o700,
            stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode),
        )

    @mock.patch.object(outbox, "start_watcher")
    def test_committed_request_remains_successful_when_watcher_launch_fails(
        self, start_watcher
    ):
        start_watcher.side_effect = OSError("process unavailable")
        result = outbox.enqueue(
            self.request(), state_dir=self.state, plugin_dir=self.plugin)

        self.assertTrue(result["queued"])
        self.assertFalse(result["watcher_started"])
        self.assertTrue(os.path.isfile(
            os.path.join(self.state, "progress-outbox", ASIN)))

    def test_tampered_request_is_rejected(self):
        path = self.enqueue()
        with open(path, "ab") as request_file:
            request_file.write(b"unexpected=true\n")
        with self.assertRaises(outbox.ProgressOutboxError):
            outbox.parse_request(path)

    def test_legacy_version_one_request_remains_readable_after_upgrade(self):
        outbox_dir = os.path.join(self.state, "progress-outbox")
        os.makedirs(outbox_dir, mode=0o700)
        path = os.path.join(outbox_dir, ASIN)
        encoded = outbox._serialize((
            ("queue_version", "1"),
            ("asin", ASIN),
            ("sequence", "1760000000000001"),
            ("native_path_hex", outbox._hex(
                "/mnt/us/documents/Test_B007N6JEII.kfx")),
            ("epub_path_hex", outbox._hex(
                "/mnt/us/koreader/cache/kindle.koplugin/test.epub")),
            ("xpointer_hex", outbox._hex(
                "/body/DocFragment/body/p/text().42")),
            ("koreader_percent", "54.25000000"),
            ("status_hex", outbox._hex("reading")),
            ("closed_at", "1760000000"),
            ("previous_long", ""),
            ("previous_short", ""),
        ))
        with open(path, "wb") as request_file:
            request_file.write(encoded)

        parsed = outbox.parse_request(path)

        self.assertEqual("1760000000000001", parsed["sequence"])
        self.assertIsNone(parsed["session_baseline"])

    def test_version_two_request_cannot_omit_its_session_schema_fields(self):
        outbox_dir = os.path.join(self.state, "progress-outbox")
        os.makedirs(outbox_dir, mode=0o700)
        path = os.path.join(outbox_dir, ASIN)
        encoded = outbox._serialize((
            ("queue_version", "2"),
            ("asin", ASIN),
            ("sequence", "1760000000000001"),
            ("native_path_hex", outbox._hex(
                "/mnt/us/documents/Test_B007N6JEII.kfx")),
            ("epub_path_hex", outbox._hex(
                "/mnt/us/koreader/cache/kindle.koplugin/test.epub")),
            ("xpointer_hex", outbox._hex(
                "/body/DocFragment/body/p/text().42")),
            ("koreader_percent", "54.25000000"),
            ("status_hex", outbox._hex("reading")),
            ("closed_at", "1760000000"),
            ("previous_long", ""),
            ("previous_short", ""),
        ))
        with open(path, "wb") as request_file:
            request_file.write(encoded)

        with self.assertRaises(outbox.ProgressOutboxError):
            outbox.parse_request(path)

    def test_partial_open_session_baseline_is_rejected(self):
        with self.assertRaises(outbox.ProgressOutboxError):
            self.enqueue(session_baseline={
                "native": PREVIOUS,
                "local": {"long": LOCAL["long"]},
            })

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_success_publishes_text_free_receipt_and_removes_request(
        self, run_agent, translate
    ):
        path = self.enqueue()
        translate.return_value = {"start": LOCAL}
        run_agent.return_value = {
            "long": LOCAL["long"], "pid": LOCAL["pid"], "percent": 39.5,
        }

        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("saved", result["action"])
        self.assertFalse(os.path.exists(path))
        receipts = outbox.list_receipts(self.state)
        self.assertEqual(1, len(receipts))
        self.assertEqual(LOCAL["long"], receipts[0]["long"])
        self.assertEqual(39.5, receipts[0]["native_percent"])
        receipt_path = os.path.join(self.state, "progress-receipts", ASIN)
        with open(receipt_path, "rb") as receipt_file:
            receipt_bytes = receipt_file.read()
        self.assertNotIn(b"documents", receipt_bytes)
        self.assertNotIn(b"DocFragment", receipt_bytes)
        self.assertNotIn(b"reading", receipt_bytes)

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_superseded_worker_keeps_latest_and_final_sweep_advances_it(
        self, run_agent, translate
    ):
        path = self.enqueue(sequence="1760000000000001")
        latest = {"long": "AAAAAAAAAAA4", "pid": 400}
        translate.side_effect = [
            {"start": LOCAL},
            {"start": latest},
        ]
        native_state = {
            "long": PREVIOUS["long"], "pid": PREVIOUS["pid"], "percent": 38.0,
        }
        saves = 0

        def agent(_plugin, _request, operation, position=None):
            nonlocal native_state, saves
            if operation == "read":
                return dict(native_state)
            saves += 1
            native_state = {
                "long": position["long"], "pid": position["pid"],
                "percent": 39.5 + saves,
            }
            if saves == 1:
                outbox.enqueue(
                    self.request(
                        sequence="1760000000000002", percent=56.0),
                    state_dir=self.state,
                    launch=False,
                )
            return dict(native_state)

        run_agent.side_effect = agent
        first = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertTrue(first["superseded"])
        self.assertEqual(
            "1760000000000002", outbox.parse_request(path)["sequence"])
        self.assertEqual(LOCAL["long"], outbox.list_receipts(self.state)[0]["long"])

        second = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertFalse(second["superseded"])
        self.assertEqual("saved", second["action"])
        self.assertFalse(os.path.exists(path))
        self.assertEqual(latest["long"], outbox.list_receipts(self.state)[0]["long"])
        self.assertEqual(2, saves)

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_superseded_during_translation_never_starts_a_stale_native_write(
        self, run_agent, translate
    ):
        path = self.enqueue(sequence="1760000000000001")

        def translate_then_supersede(*_args, **_kwargs):
            outbox.enqueue(
                self.request(sequence="1760000000000002", percent=56.0),
                state_dir=self.state,
                launch=False,
            )
            return {"start": LOCAL}

        translate.side_effect = translate_then_supersede
        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("superseded", result["action"])
        self.assertTrue(result["superseded"])
        run_agent.assert_not_called()
        self.assertEqual(
            "1760000000000002", outbox.parse_request(path)["sequence"])

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_published_debug_does_not_change_shared_directory_permissions(
        self, run_agent, translate
    ):
        shared = os.path.join(self.temp.name, "shared-settings")
        os.mkdir(shared, 0o755)
        os.chmod(shared, 0o755)
        debug = os.path.join(shared, "progress.log")
        path = self.enqueue()
        translate.return_value = {"start": LOCAL}
        run_agent.return_value = {
            "long": LOCAL["long"], "pid": LOCAL["pid"], "percent": 39.5,
        }

        outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=debug)

        self.assertEqual(0o755, stat.S_IMODE(os.stat(shared).st_mode))

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_concurrent_native_and_koreader_moves_fail_closed(
        self, run_agent, translate
    ):
        path = self.enqueue(previous=PREVIOUS)
        translate.return_value = {"start": LOCAL}
        run_agent.return_value = NATIVE

        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("conflict", result["action"])
        run_agent.assert_called_once()
        self.assertFalse(os.path.exists(path))
        self.assertEqual([], outbox.list_receipts(self.state))

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_nearby_concurrent_moves_still_fail_closed(
        self, run_agent, translate
    ):
        path = self.enqueue(previous=PREVIOUS)
        nearby_native = {
            "long": NATIVE["long"],
            "pid": LOCAL["pid"] + 5,
            "percent": 41.0,
        }
        translate.return_value = {"start": LOCAL}
        run_agent.return_value = nearby_native

        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("conflict", result["action"])
        run_agent.assert_called_once()
        self.assertFalse(os.path.exists(path))
        self.assertEqual([], outbox.list_receipts(self.state))

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_session_local_move_wins_when_native_did_not_move(
        self, run_agent, translate
    ):
        old_receipt = {"long": "AAAAAAAAAAA0", "pid": 50}
        session_native = {
            "long": "AAAAAAAAAAA3", "pid": 300, "percent": 41.0,
        }
        session_local = {"long": "AAAAAAAAAAA1", "pid": 100}
        path = self.enqueue(
            previous=old_receipt,
            session_baseline={
                "native": session_native,
                "local": session_local,
            })
        translate.return_value = {"start": LOCAL}
        run_agent.side_effect = [
            session_native,
            {"long": LOCAL["long"], "pid": LOCAL["pid"], "percent": 42.0},
        ]

        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("saved", result["action"])
        self.assertEqual(2, run_agent.call_count)
        self.assertEqual("save", run_agent.call_args.args[2])
        self.assertEqual(LOCAL, run_agent.call_args.args[3])
        self.assertEqual(LOCAL["long"], outbox.list_receipts(self.state)[0]["long"])

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_session_native_move_wins_when_koreader_did_not_move(
        self, run_agent, translate
    ):
        path = self.enqueue(session_baseline={
            "native": PREVIOUS,
            "local": LOCAL,
        })
        translate.return_value = {"start": LOCAL}
        run_agent.return_value = NATIVE

        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("native_won", result["action"])
        run_agent.assert_called_once()
        self.assertEqual([], outbox.list_receipts(self.state))

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_session_two_sided_move_remains_a_conflict(
        self, run_agent, translate
    ):
        open_local = {"long": "AAAAAAAAAAA4", "pid": 400}
        path = self.enqueue(session_baseline={
            "native": PREVIOUS,
            "local": open_local,
        })
        translate.return_value = {"start": LOCAL}
        run_agent.return_value = NATIVE

        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("conflict", result["action"])
        run_agent.assert_called_once()
        self.assertEqual([], outbox.list_receipts(self.state))

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_session_unchanged_divergence_does_not_overwrite_either_side(
        self, run_agent, translate
    ):
        path = self.enqueue(session_baseline={
            "native": NATIVE,
            "local": LOCAL,
        })
        translate.return_value = {"start": LOCAL}
        run_agent.return_value = NATIVE

        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("no_session_change", result["action"])
        run_agent.assert_called_once()
        self.assertEqual([], outbox.list_receipts(self.state))

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_unchanged_koreader_never_overwrites_newer_native(
        self, run_agent, translate
    ):
        path = self.enqueue(previous=PREVIOUS)
        translate.return_value = {"start": PREVIOUS}
        run_agent.return_value = NATIVE

        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("native_won", result["action"])
        run_agent.assert_called_once()
        self.assertFalse(os.path.exists(path))
        self.assertEqual([], outbox.list_receipts(self.state))

    @mock.patch.object(outbox, "translate_pair")
    @mock.patch.object(outbox, "_run_agent")
    def test_already_current_position_is_receipted_without_save(
        self, run_agent, translate
    ):
        path = self.enqueue(previous=PREVIOUS)
        current = {"long": LOCAL["long"], "pid": LOCAL["pid"],
                   "percent": 39.5}
        translate.return_value = {"start": LOCAL}
        run_agent.return_value = current

        result = outbox.process_request(
            path, state_dir=self.state, plugin_dir=self.plugin,
            debug_path=self.debug)

        self.assertEqual("already_current", result["action"])
        run_agent.assert_called_once()
        self.assertEqual("read", run_agent.call_args.args[2])
        self.assertEqual(LOCAL["long"], outbox.list_receipts(self.state)[0]["long"])

    def test_transient_failure_keeps_request_for_replay(self):
        path = self.enqueue()
        with mock.patch.object(
            outbox, "translate_pair", return_value={"start": LOCAL}
        ), mock.patch.object(
            outbox, "_run_agent",
            side_effect=outbox.ProgressOutboxTransient("busy"),
        ):
            with self.assertRaises(outbox.ProgressOutboxTransient):
                outbox.process_request(
                    path, state_dir=self.state, plugin_dir=self.plugin,
                    debug_path=self.debug)
        self.assertTrue(os.path.isfile(path))


if __name__ == "__main__":
    unittest.main()
