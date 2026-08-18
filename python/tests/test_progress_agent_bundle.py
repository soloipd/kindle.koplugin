import os
import shutil
import struct
import subprocess
import tempfile
import time
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
AGENT_JAR = ROOT / "bin" / "native-reading-progress-agent-v7.jar"
AGENT_SOURCE = ROOT / "agent" / "src" / "KindlePluginReadingProgressAgentV7.java"
RUNNER = ROOT / "bin" / "sync-native-progress"
AGENT_BUILDER = ROOT / "scripts" / "build_native_progress_agent"
AGENT_CHECKER = ROOT / "scripts" / "check_native_progress_agent"
AGENT_TEST_SDK_JARS = sorted((ROOT / "build-cache" / "agent-v7" / "jars").glob("*.jar"))


def java_tool_works(name, version_arg):
    executable = shutil.which(name)
    if not executable:
        return False
    try:
        subprocess.run(
            [executable, version_arg],
            check=True,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return True


JAVAC_WORKS = java_tool_works("javac", "-version")
JAVA_WORKS = java_tool_works("java", "-version")
JAR_WORKS = java_tool_works("jar", "--version")


class ReadingProgressAgentBundleTests(unittest.TestCase):
    def test_runner_and_manifest_select_v7_agent(self):
        self.assertIn(
            'native-reading-progress-agent-v7.jar',
            RUNNER.read_text(encoding="utf-8"),
        )
        with zipfile.ZipFile(AGENT_JAR) as bundle:
            manifest = bundle.read("META-INF/MANIFEST.MF").decode("utf-8")
            names = set(bundle.namelist())
        self.assertIn("Agent-Class: KindlePluginReadingProgressAgentV7", manifest)
        self.assertIn("KindlePluginReadingProgressAgentV7.class", names)
        self.assertIn("KindlePluginReadingProgressAgentV7$1.class", names)

    def test_release_build_includes_the_complete_native_progress_bridge(self):
        build_script = (ROOT / "python_build.sh").read_text(encoding="utf-8")
        self.assertNotIn('cp -r bin/ "$STAGING/bin/"', build_script)
        self.assertIn(
            'cp "$VERIFIED_AGENT_JAR" "$STAGING/bin/native-reading-progress-agent-v7.jar"',
            build_script,
        )
        self.assertIn('test -x "$STAGING/bin/sync-native-progress"', build_script)
        self.assertIn('test -x "$STAGING/bin/watch-close-progress"', build_script)
        self.assertIn(
            'test -f "$STAGING/bin/native-reading-progress-agent-v7.jar"',
            build_script,
        )
        self.assertIn('test -f "$STAGING/dist/annotation_position.py"', build_script)
        self.assertIn('test -f "$STAGING/dist/progress_outbox.py"', build_script)
        self.assertIn("libxml2.so.2", build_script)
        self.assertIn("libxslt.so.1", build_script)
        self.assertIn("libexslt.so.0", build_script)
        self.assertNotIn("Dockerfile.lxml-runtime", build_script)
        self.assertIn("libicuuc.so.67", build_script)
        self.assertIn("libicudata.so.67", build_script)
        self.assertIn("libgcrypt.so.20", build_script)
        self.assertIn('cp "$PILLOW_ASSET_DIR/crypto_hook.so"', build_script)
        self.assertIn("soupsieve", build_script)
        self.assertIn("if docker buildx version", build_script)
        self.assertIn("docker build \\", build_script)
        for obsolete in ("v2", "v3", "v6"):
            self.assertIn(
                f'test ! -e "$STAGING/bin/native-reading-progress-agent-{obsolete}.jar"',
                build_script,
            )

    def test_runner_can_publish_a_request_scoped_private_result(self):
        runner = RUNNER.read_text(encoding="utf-8")
        self.assertIn("kindle-progress-worker-", runner)
        self.assertIn('[ "$private_id" = "$payload_id" ]', runner)
        self.assertIn('chmod 0600 "$private_temp"', runner)

    def test_close_lifecycle_never_forks_a_second_koreader_process(self):
        sync_source = (ROOT / "lua" / "reading_state_sync.lua").read_text(
            encoding="utf-8")
        reader_source = (ROOT / "lua" / "readerui_ext.lua").read_text(
            encoding="utf-8")
        self.assertNotIn("_runBackgroundCloseTask", sync_source)
        self.assertNotIn("background_process_runner", sync_source)
        self.assertIn("enqueueCloseProgress", sync_source)
        self.assertLess(
            reader_source.index("syncToKindleAutomaticInBackground"),
            reader_source.index("self.original_methods.onClose(reader_self"),
        )

    def test_durable_worker_invokes_shell_bridges_without_fuse_x_ok_checks(self):
        worker = (ROOT / "python" / "progress_outbox.py").read_text(
            encoding="utf-8")
        self.assertIn('["/bin/sh", watcher]', worker)
        self.assertIn('["/bin/sh", runner, payload_path, result_path]', worker)
        self.assertNotIn("os.access(", worker)

    def test_bundled_agent_targets_java_8_and_contains_durability_checks(self):
        with zipfile.ZipFile(AGENT_JAR) as bundle:
            bytecode = bundle.read("KindlePluginReadingProgressAgentV7.class")
        self.assertEqual(b"\xca\xfe\xba\xbe", bytecode[:4])
        self.assertEqual(52, struct.unpack(">H", bytecode[6:8])[0])
        for marker in (
            b"LprSidecarAdapter",
            b"verify_local_lpr",
            b"local_progress_verified",
            b"local LPR durability check failed",
            b"native_percent",
            b"native rendered percentage unavailable",
            b"catalog_progress_saved",
            b"ContentCatalogLprUtils",
            b"save_native_progress",
            b"single_flight",
            b"agent already running",
            b"kindle-reading-progress-agent",
            b"elapsed_",
        ):
            self.assertIn(marker, bytecode)

    def test_target_agent_enforces_single_flight_inside_the_framework_jvm(self):
        source = AGENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn("java.util.concurrent.atomic.AtomicBoolean", source)
        self.assertIn(
            "AGENT_RUNNING.compareAndSet(false, true)",
            source,
        )
        self.assertIn('failed_stage=single_flight', source)
        self.assertIn('error_class=agent already running', source)
        self.assertIn("AGENT_RUNNING.set(false)", source)
        self.assertIn('"kindle-reading-progress-agent"', source)
        self.assertIn("worker.setDaemon(true)", source)

        acquire = source.index("AGENT_RUNNING.compareAndSet(false, true)")
        open_book = source.index("content.dt(nativePath)")
        release = source.rindex("AGENT_RUNNING.set(false)")
        self.assertLess(acquire, open_book)
        self.assertLess(open_book, release)

    def test_target_agent_deadline_interrupts_and_fences_stale_work(self):
        source = AGENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn("DEFAULT_REQUEST_TIMEOUT_MS = 10000", source)
        self.assertIn('"kindle-reading-progress-watchdog"', source)
        self.assertIn("worker.interrupt()", source)
        self.assertIn("request expired", source)
        self.assertIn("ensureActive(lease)", source)

        open_book = source.index("book = content.dt(nativePath)")
        stage_lpr = source.index("adapter.a(lpr)")
        save_book = source.index("book.Ue()")
        refresh = source.index("sdk.xQ()")
        catalog = source.index('item.setProperty("percentFinished"')
        for mutation in (stage_lpr, save_book, refresh, catalog):
            fence = source.rfind("ensureActive(lease)", open_book, mutation)
            self.assertGreater(fence, open_book)

    def test_agent_build_uses_reviewed_stubs_and_disables_processors(self):
        builder = AGENT_BUILDER.read_text(encoding="utf-8")
        self.assertIn('SDK_STUB_DIR="$ROOT_DIR/agent/sdk-stubs/src"', builder)
        self.assertIn("-proc:none", builder)
        self.assertNotIn("KINDLE_AGENT_SDK_DIR", builder)
        self.assertIn('find "$SDK_STUB_DIR"', builder)
        self.assertIn("--date=1980-01-01T00:00:02Z", builder)

    def test_java_toolchain_rejects_macos_placeholders(self):
        toolchain = (ROOT / "scripts" / "java_toolchain.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('"$bin_dir/javac" -version', toolchain)
        self.assertIn('"$bin_dir/jar" --help', toolchain)
        self.assertIn("-- '--date'", toolchain)
        for script_name in (
            "build_native_progress_agent",
            "check_native_progress_agent",
            "build_voucher_extractor",
            "test_python",
        ):
            script = (ROOT / "scripts" / script_name).read_text(encoding="utf-8")
            self.assertIn("java_toolchain.sh", script)

    def test_agent_checker_rebuilds_and_compares_class_bytes(self):
        builder = AGENT_BUILDER.read_text(encoding="utf-8")
        checker = AGENT_CHECKER.read_text(encoding="utf-8")
        build_script = (ROOT / "python_build.sh").read_text(encoding="utf-8")
        self.assertIn("KINDLE_AGENT_OUTPUT", builder)
        self.assertIn("KINDLE_AGENT_SKIP_CHECK", builder)
        self.assertIn("build_native_progress_agent", checker)
        self.assertIn("KINDLE_AGENT_OUTPUT", checker)
        self.assertIn("cmp -s", checker)
        self.assertIn('cmp -s "$JAR" "$REBUILT_JAR"', checker)
        self.assertIn("KINDLE_AGENT_VERIFIED_OUTPUT", checker)
        self.assertIn('cp "$REBUILT_JAR" "$verified_temp"', checker)
        verify = build_script.index(
            'KINDLE_AGENT_VERIFIED_OUTPUT="$VERIFIED_AGENT_JAR"'
        )
        package = build_script.index(
            'cp "$VERIFIED_AGENT_JAR" "$STAGING/bin/native-reading-progress-agent-v7.jar"'
        )
        self.assertLess(verify, package)
        self.assertNotIn(
            'cp bin/native-reading-progress-agent-v7.jar "$STAGING/bin/"',
            build_script,
        )

    @unittest.skipUnless(
        JAVAC_WORKS and JAR_WORKS,
        "A Java toolchain is required to export a verified agent",
    )
    def test_agent_checker_exports_the_freshly_rebuilt_verified_jar(self):
        with tempfile.TemporaryDirectory(prefix="verified-progress-agent-") as temp:
            verified = Path(temp) / "native-reading-progress-agent-v7.jar"
            env = os.environ.copy()
            env["KINDLE_AGENT_VERIFIED_OUTPUT"] = str(verified)
            subprocess.run(
                [str(AGENT_CHECKER)],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertTrue(verified.is_file())
            with zipfile.ZipFile(AGENT_JAR) as current_bundle:
                current_class = current_bundle.read(
                    "KindlePluginReadingProgressAgentV7.class"
                )
            with zipfile.ZipFile(verified) as verified_bundle:
                verified_class = verified_bundle.read(
                    "KindlePluginReadingProgressAgentV7.class"
                )
            self.assertEqual(current_class, verified_class)

    @unittest.skipUnless(
        JAVAC_WORKS and JAVA_WORKS and AGENT_TEST_SDK_JARS,
        "Java toolchain and local Kindle SDK test jars are required",
    )
    def test_attached_agent_rejects_a_second_request_while_worker_is_active(self):
        target_source = """
public final class SingleFlightTarget {
    private SingleFlightTarget() {}
    public static void main(String[] ignored) throws Exception {
        System.out.println("ready");
        System.out.flush();
        Thread.sleep(30000L);
    }
}
"""

        def payload(request_id):
            native_path = "/mnt/us/documents/single-flight-test.kfx"
            return (
                "version=1\n"
                f"request_id={request_id}\n"
                "asin=B007N6JEII\n"
                "operation=read\n"
                f"native_path_hex={native_path.encode().hex()}\n"
                "sync_timeout_ms=500\n"
            )

        def result_path(request_id):
            return Path(f"/tmp/kindle-progress-result-{request_id}.log")

        def wait_for_result(request_id):
            path = result_path(request_id)
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if path.exists():
                    values = {}
                    for line in path.read_text(encoding="utf-8").splitlines():
                        key, separator, value = line.partition("=")
                        if separator:
                            values[key] = value
                    if values.get("success") in {"true", "false"}:
                        return values
                time.sleep(0.05)
            self.fail(f"terminal result not written for request {request_id}")

        unique = f"{os.getpid()}{time.time_ns() % 1000000000:09d}"
        request_ids = [unique + suffix for suffix in ("1", "2", "3")]
        payload_paths = [
            Path(f"/tmp/kindle-progress-{request_id}.properties")
            for request_id in request_ids
        ]
        cleanup_paths = payload_paths + [
            result_path(request_id) for request_id in request_ids
        ]
        java_env = os.environ.copy()
        java_env["TMPDIR"] = "/tmp"
        target = None
        try:
            for path in cleanup_paths:
                path.unlink(missing_ok=True)
            os.mkfifo(payload_paths[0], 0o600)

            with tempfile.TemporaryDirectory(prefix="progress-agent-test-") as temp:
                temp_path = Path(temp)
                target_java = temp_path / "SingleFlightTarget.java"
                target_java.write_text(target_source, encoding="utf-8")
                subprocess.run(
                    [
                        "javac", "-d", temp,
                        str(ROOT / "agent" / "src" / "AttachLauncher.java"),
                        str(target_java),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                target = subprocess.Popen(
                    [
                        "java", "-Djava.io.tmpdir=/tmp",
                        "-XX:+StartAttachListener", "-cp",
                        os.pathsep.join([temp, *map(str, AGENT_TEST_SDK_JARS)]),
                        "SingleFlightTarget",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    env=java_env,
                )
                self.assertEqual("ready", target.stdout.readline().strip())

                attach = [
                    "java", "--add-modules", "jdk.attach", "-cp", temp,
                    "AttachLauncher", str(target.pid), str(AGENT_JAR),
                ]
                first_started = time.monotonic()
                first = subprocess.run(
                    attach + [str(payload_paths[0])],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=15,
                    env=java_env,
                )
                self.assertLess(time.monotonic() - first_started, 12.0)
                self.assertEqual(0, first.returncode, first.stderr)

                payload_paths[1].write_text(payload(request_ids[1]), encoding="utf-8")
                second = subprocess.run(
                    attach + [str(payload_paths[1])],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env=java_env,
                )
                self.assertEqual(0, second.returncode, second.stderr)
                second_result = wait_for_result(request_ids[1])
                self.assertEqual("single_flight", second_result.get("failed_stage"))
                self.assertEqual("agent already running", second_result.get("error_class"))

                with payload_paths[0].open("w", encoding="utf-8") as fifo:
                    fifo.write(payload(request_ids[0]))
                first_result = wait_for_result(request_ids[0])
                self.assertNotEqual("single_flight", first_result.get("failed_stage"))
                time.sleep(0.1)

                payload_paths[2].write_text(payload(request_ids[2]), encoding="utf-8")
                third = subprocess.run(
                    attach + [str(payload_paths[2])],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=5,
                    env=java_env,
                )
                self.assertEqual(0, third.returncode, third.stderr)
                third_result = wait_for_result(request_ids[2])
                self.assertNotEqual("single_flight", third_result.get("failed_stage"))
        finally:
            if target is not None:
                target.terminate()
                try:
                    target.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    target.kill()
                    target.wait(timeout=5)
                target.stdout.close()
                target.stderr.close()
            for path in cleanup_paths:
                path.unlink(missing_ok=True)

    def test_runner_caps_attach_and_result_waits(self):
        runner = RUNNER.read_text(encoding="utf-8")
        self.assertIn("ATTACH_TIMEOUT_SECONDS=12", runner)
        self.assertIn("RESULT_POLL_ATTEMPTS=12", runner)
        self.assertIn('timeout "$ATTACH_TIMEOUT_SECONDS"', runner)

    def test_runner_lock_is_published_atomically_and_released_by_its_owner(self):
        runner = RUNNER.read_text(encoding="utf-8")
        self.assertIn('LOCK_FILE="/tmp/kindle-progress-sync.lock"', runner)
        self.assertIn('owner_token="$$:$request_id"', runner)
        self.assertIn('umask 077', runner)
        self.assertIn(
            'owner_dir="$(mktemp -d "/tmp/kindle-progress-sync.XXXXXX")"',
            runner,
        )
        self.assertIn('owner_temp="$owner_dir/owner"', runner)
        self.assertNotIn(
            'owner_temp="/tmp/kindle-progress-sync.owner.$$.$request_id"',
            runner,
        )
        self.assertIn('ln "$owner_temp" "$LOCK_FILE"', runner)
        self.assertIn('test "$published_owner" = "$owner_token"', runner)
        self.assertIn("LOCK_PUBLISH_ATTEMPTS=", runner)
        self.assertNotIn('mkdir "$LOCK_FILE"', runner)

    def test_old_predictable_owner_symlink_cannot_redirect_the_runner_write(self):
        runner = RUNNER.read_text(encoding="utf-8")
        real_sed = shutil.which("sed")
        self.assertIsNotNone(real_sed)
        request_id = f"{os.getpid()}{time.time_ns() % 1000000000:09d}"
        payload = Path(f"/tmp/kindle-progress-{request_id}.properties")
        old_owner_path = None
        process = None
        with tempfile.TemporaryDirectory(prefix="progress-owner-runner-") as temp:
            temp_path = Path(temp)
            plugin_dir = temp_path / "plugin"
            (plugin_dir / "bin" / "classes").mkdir(parents=True)
            (plugin_dir / "bin" / "native-reading-progress-agent-v7.jar").write_bytes(
                b"test-agent"
            )
            (plugin_dir / "bin" / "classes" / "AttachLauncher.class").write_bytes(
                b"test-launcher"
            )
            # This path is only checked for executability; the mocked ps()
            # below deliberately stops before Java attachment. Use an existing
            # executable so the test also works under the fallback container's
            # intentionally noexec /tmp mount.
            fake_java_path = shutil.which("true")
            self.assertIsNotNone(fake_java_path)
            fake_java = Path(fake_java_path)
            lock_file = temp_path / "progress.lock"
            attach_log = temp_path / "attach.log"
            published_result = temp_path / "published.log"
            private_template = temp_path / "kindle-progress-sync.XXXXXX"
            patched = runner.replace(
                'JAVA_BIN="/usr/java/bin/java"', f'JAVA_BIN="{fake_java}"'
            ).replace(
                'PLUGIN_DIR="/mnt/us/koreader/plugins/kindle.koplugin"',
                f'PLUGIN_DIR="{plugin_dir}"',
            ).replace(
                'LOCK_FILE="/tmp/kindle-progress-sync.lock"',
                f'LOCK_FILE="{lock_file}"',
            ).replace(
                'ATTACH_LOG="/tmp/kindle-progress-attach.log"',
                f'ATTACH_LOG="{attach_log}"',
            ).replace(
                'PUBLISHED_RESULT="/mnt/us/koreader/settings/kindle_native_progress_debug.log"',
                f'PUBLISHED_RESULT="{published_result}"',
            ).replace(
                '"/tmp/kindle-progress-sync.XXXXXX"',
                f'"{private_template}"',
            )
            runner_copy = temp_path / "sync-native-progress"
            runner_copy.write_text(patched, encoding="utf-8")
            runner_copy.chmod(0o755)

            gate_seen = temp_path / "sed-seen"
            gate_release = temp_path / "sed-release"
            command_overrides = (
                "sed() {\n"
                "if [ ! -e \"$SYNC_SED_SEEN\" ]; then\n"
                "    : >\"$SYNC_SED_SEEN\"\n"
                "    while [ ! -e \"$SYNC_SED_RELEASE\" ]; do sleep 0.01; done\n"
                "fi\n"
                f'"{real_sed}" "$@"\n'
                "}\n"
                "ps() { return 0; }\n"
            )
            patched = patched.replace(
                "set -u\n", "set -u\n" + command_overrides, 1
            )
            runner_copy.write_text(patched, encoding="utf-8")

            victim = temp_path / "victim"
            victim.write_text("unchanged\n", encoding="utf-8")
            payload.write_text(
                "version=1\n"
                f"request_id={request_id}\n"
                "asin=B007N6JEII\n"
                "operation=read\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["SYNC_SED_SEEN"] = str(gate_seen)
            env["SYNC_SED_RELEASE"] = str(gate_release)
            try:
                process = subprocess.Popen(
                    ["/bin/sh", str(runner_copy), str(payload)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    env=env,
                )
                deadline = time.monotonic() + 5
                while not gate_seen.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                if not gate_seen.exists():
                    stdout, stderr = process.communicate(timeout=2)
                    self.fail(
                        "runner did not reach payload parsing; "
                        f"exit={process.returncode}, stdout={stdout!r}, stderr={stderr!r}"
                    )
                old_owner_path = Path(
                    f"/tmp/kindle-progress-sync.owner.{process.pid}.{request_id}"
                )
                old_owner_path.unlink(missing_ok=True)
                old_owner_path.symlink_to(victim)
                gate_release.touch()
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(5, process.returncode, stdout + stderr)
                self.assertEqual("unchanged\n", victim.read_text(encoding="utf-8"))
                self.assertFalse(lock_file.exists())
                self.assertEqual([], list(temp_path.glob("kindle-progress-sync.*")))
            finally:
                gate_release.touch(exist_ok=True)
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                if process is not None:
                    if process.stdout is not None:
                        process.stdout.close()
                    if process.stderr is not None:
                        process.stderr.close()
                payload.unlink(missing_ok=True)
                if old_owner_path is not None:
                    old_owner_path.unlink(missing_ok=True)

    def test_source_reinserts_lpr_before_saving(self):
        source = AGENT_SOURCE.read_text(encoding="utf-8")
        stage = source.index("adapter.a(lpr)")
        save = source.index("book.Ue()")
        close = source.index("book.close()", save)
        reopen = source.index("content.dt(nativePath)", close)
        verify = source.index("local_progress_verified=true", reopen)
        self.assertLess(stage, save)
        self.assertLess(save, close)
        self.assertLess(close, reopen)
        self.assertLess(reopen, verify)

    def test_native_percentage_uses_kindles_rendered_progress_fraction(self):
        source = AGENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn("position.UG() * 100.0", source)
        self.assertNotIn("position.nR() * 100.0", source)

    def test_native_catalog_transaction_publishes_the_shelf_percentage(self):
        source = AGENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn('item.setProperty("percentFinished"', source)
        self.assertIn("ContentCatalogLprUtils.a(sdk, catalog, item)", source)
        self.assertIn('catalog_progress_saved=" + catalogSaved', source)


if __name__ == "__main__":
    unittest.main()
