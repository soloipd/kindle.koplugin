import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILD_SCRIPT = ROOT / "python_build.sh"
TEST_RUNNER = ROOT / "scripts" / "test_python"
TEST_DOCKERFILE = ROOT / ".github" / "Dockerfile.python-tests"
WRAPPER_DOCKERFILE = ROOT / ".github" / "Dockerfile.wrapper"


class ReleaseBuildSecurityTests(unittest.TestCase):
    @staticmethod
    def _fake_docker_function():
        return (
            "docker() {\n"
            "{\n"
            "    printf '%s\\n' CALL\n"
            "    for argument in \"$@\"; do\n"
            "        printf 'ARG=%s\\n' \"$argument\"\n"
            "    done\n"
            "} >>\"$DOCKER_LOG\"\n"
            "return 0\n"
            "}\n"
        )

    @staticmethod
    def _read_fake_docker_calls(log_path):
        calls = []
        current = None
        for line in log_path.read_text(encoding="utf-8").splitlines():
            if line == "CALL":
                current = []
                calls.append(current)
            elif line.startswith("ARG=") and current is not None:
                current.append(line.removeprefix("ARG="))
        return calls

    def test_pillow_builder_uses_immutable_remote_identities(self):
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'PILLOW_BUILDER_IMAGE="arm32v7/debian:bullseye@sha256:'
            'b4ac940510634c13c9ce5b1124d2b5a90b5738408637e64e970fe927da895bed"',
            script,
        )
        self.assertIn('DEBIAN_SNAPSHOT="20260803T000000Z"', script)
        self.assertIn(
            'PILLOW_SOURCE_SHA256="a830b1a40919539d07806aa58e1b114df'
            '53ddd43213d9c8b75847eee6c0182b5"',
            script,
        )
        self.assertIn(
            'PYBIND11_WHEEL_SHA256="aa8f0aa6e0a94d3b64adfc38f560f33'
            'f15e589be2175e103c0a33c6bce55ee89"',
            script,
        )
        self.assertIn("snapshot.debian.org/archive/debian/", script)
        self.assertIn("snapshot.debian.org/archive/debian-security/", script)
        self.assertNotIn("arm32v7/debian:bullseye bash -c", script)

    def test_downloaded_executable_inputs_are_verified_before_use(self):
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'CPYTHON_TARBALL_SHA256="822b49f675b04581e4244136272c4662e'
            '8475c002e65c08a9f75911e0e935627"',
            script,
        )
        verify_python = script.index(
            'verify_sha256 "$CPYTHON_TARBALL" "$CPYTHON_TARBALL_SHA256"'
        )
        extract_python = script.index('tar xzf "$CPYTHON_TARBALL"')
        self.assertLess(verify_python, extract_python)

        verify_pillow = script.index(
            'verify_sha256 "$source_archive" "$PILLOW_SOURCE_SHA256"'
        )
        verify_pybind = script.index(
            'verify_sha256 "$pybind11_wheel" "$PYBIND11_WHEEL_SHA256"'
        )
        build_pillow = script.index("-m pip wheel", verify_pillow)
        self.assertLess(verify_pillow, build_pillow)
        self.assertLess(verify_pybind, build_pillow)
        pillow_command = script[build_pillow : build_pillow + 350]
        self.assertIn("--no-index", pillow_command)
        self.assertIn("--no-build-isolation", pillow_command)

    def test_builder_image_reference_contains_a_real_sha256_digest(self):
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        match = re.search(
            r'PILLOW_BUILDER_IMAGE="arm32v7/debian:bullseye@sha256:([a-f0-9]{64})"',
            script,
        )
        self.assertIsNotNone(match)

    def test_release_runtime_does_not_trust_marker_only_cache_entries(self):
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('CACHE_STAMP=', script)
        self.assertNotIn('touch "$CACHE_STAMP"', script)

    def test_pillow_assets_are_rebuilt_from_verified_inputs(self):
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        function = script[
            script.index("build_pillow_arm_assets()") :
            script.index('echo "=== Kindle Helper Build', script.index("build_pillow_arm_assets()"))
        ]
        self.assertNotIn('asset_dir/.stamp', function)
        self.assertIn('rm -rf "$asset_dir"', function)
        self.assertLess(
            function.index('verify_sha256 "$source_archive"'),
            function.index('docker run'),
        )

    def test_pillow_builder_mounts_the_verified_ca_by_absolute_path(self):
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        function = script[
            script.index("build_pillow_arm_assets()") :
            script.index('echo "=== Kindle Helper Build', script.index("build_pillow_arm_assets()"))
        ]
        self.assertIn('python_dist="$(cd "$1" && pwd)"', function)
        self.assertIn(
            '-v "$ca_bundle:/etc/ssl/certs/ca-certificates.crt:ro"',
            function,
        )

    def test_snapshot_and_downloaded_packages_have_immutable_identities(self):
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn(" http://snapshot.debian.org", script)
        self.assertIn(" https://snapshot.debian.org", script)
        for package in ("LXML", "PYCRYPTODOME", "BEAUTIFULSOUP", "SOUPSIEVE"):
            self.assertRegex(script, rf'{package}_WHEEL_URL="https://[^\"]+"')
            self.assertRegex(script, rf'{package}_WHEEL_SHA256="[a-f0-9]{{64}}"')
            self.assertIn(
                f'verify_sha256 "${{{package}_WHEEL}}" "${{{package}_WHEEL_SHA256}}"',
                script,
            )

    def test_all_release_builder_images_are_digest_pinned(self):
        for dockerfile in (WRAPPER_DOCKERFILE,):
            from_lines = [
                line for line in dockerfile.read_text(encoding="utf-8").splitlines()
                if line.startswith("FROM ")
            ]
            self.assertTrue(from_lines, dockerfile)
            for line in from_lines:
                self.assertRegex(line, r"@sha256:[a-f0-9]{64}$")
        self.assertFalse((ROOT / ".github" / "Dockerfile.lxml-runtime").exists())
        self.assertFalse((ROOT / ".github" / "Dockerfile.crypto_hook").exists())

    def test_python_fallback_cannot_write_the_checkout_or_reach_the_network(self):
        runner = TEST_RUNNER.read_text(encoding="utf-8")
        for control in (
            "--network none",
            "--read-only",
            "--cap-drop ALL",
            "--security-opt no-new-privileges",
            "--tmpfs /tmp:rw,nosuid,nodev,noexec",
            'PYTHONDONTWRITEBYTECODE=1',
            '"$ROOT_DIR:/work:ro"',
        ):
            self.assertIn(control, runner)

    def test_python_fallback_base_images_are_digest_pinned(self):
        dockerfile = TEST_DOCKERFILE.read_text(encoding="utf-8")
        from_lines = [
            line for line in dockerfile.splitlines() if line.startswith("FROM ")
        ]
        self.assertEqual(2, len(from_lines))
        for line in from_lines:
            self.assertRegex(line, r"@sha256:[a-f0-9]{64}(?: AS [a-z]+)?$")

    def test_context_free_dockerfiles_receive_exclusive_empty_contexts(self):
        build_script = BUILD_SCRIPT.read_text(encoding="utf-8")
        wrapper_function = build_script[
            build_script.index("build_arm_image()") :
            build_script.index("build_pillow_arm_assets()")
        ]
        self.assertIn("kindle-wrapper-context.XXXXXX", wrapper_function)
        self.assertIn('"$build_context" || build_status=$?', wrapper_function)
        self.assertNotRegex(wrapper_function, r"(?m)^\s+\.\s*$")

        runner = TEST_RUNNER.read_text(encoding="utf-8")
        self.assertIn("kindle-python-test-context.XXXXXX", runner)
        self.assertIn('    "$BUILD_CONTEXT"', runner)
        self.assertNotIn('    "$ROOT_DIR"\nexec docker run', runner)

    def test_wrapper_build_sends_only_an_empty_temporary_context(self):
        build_script = BUILD_SCRIPT.read_text(encoding="utf-8")
        wrapper_function = build_script[
            build_script.index("build_arm_image()") :
            build_script.index("build_pillow_arm_assets()")
        ]
        with tempfile.TemporaryDirectory(prefix="kindle-context-test-") as temp:
            temp_path = Path(temp)
            log_path = temp_path / "docker.log"
            harness = temp_path / "run-wrapper-build"
            harness.write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\n"
                + self._fake_docker_function()
                + wrapper_function
                + "\nbuild_arm_image test-image test.Dockerfile\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["DOCKER_LOG"] = str(log_path)
            env["TMPDIR"] = str(temp_path)
            subprocess.run(["/bin/bash", str(harness)], check=True, env=env)

            calls = self._read_fake_docker_calls(log_path)
            build_call = next(call for call in calls if call[:2] == ["buildx", "build"])
            context = Path(build_call[-1])
            self.assertEqual(temp_path, context.parent)
            self.assertTrue(context.name.startswith("kindle-wrapper-context."))
            self.assertFalse(context.exists())

    def test_python_fallback_sends_only_an_empty_temporary_context(self):
        with tempfile.TemporaryDirectory(prefix="kindle-python-context-test-") as temp:
            temp_path = Path(temp)
            log_path = temp_path / "docker.log"
            runner = TEST_RUNNER.read_text(encoding="utf-8")
            runner = runner.replace(
                'ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"',
                f'ROOT_DIR="{ROOT}"',
            ).replace(
                "set -euo pipefail\n",
                "set -euo pipefail\n" + self._fake_docker_function(),
                1,
            ).replace("exec docker run", "docker run")
            harness = temp_path / "run-python-fallback"
            harness.write_text(runner, encoding="utf-8")
            env = os.environ.copy()
            env["DOCKER_LOG"] = str(log_path)
            env["TMPDIR"] = str(temp_path)
            env["KINDLE_TEST_PYTHON"] = "missing-kindle-test-python"
            subprocess.run(["/bin/bash", str(harness)], check=True, env=env)

            calls = self._read_fake_docker_calls(log_path)
            build_call = next(call for call in calls if call and call[0] == "build")
            context = Path(build_call[-1])
            self.assertEqual(temp_path, context.parent)
            self.assertTrue(context.name.startswith("kindle-python-test-context."))
            self.assertNotEqual(ROOT, context)
            self.assertFalse(context.exists())


if __name__ == "__main__":
    unittest.main()
