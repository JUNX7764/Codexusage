import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UPDATE = ROOT / "scripts" / "update.sh"
RELEASE = ROOT / "scripts" / "release.sh"
BUILD = ROOT / "build.sh"


def setting(name, source=UPDATE):
    match = re.search(rf'^{name}="?([^"\n]+)"?$', source.read_text(), re.MULTILINE)
    if not match:
        raise AssertionError(f"missing {name} in {source}")
    return match.group(1)


REPO = setting("REPO")
APP_NAME = setting("APP_NAME")
EXECUTABLE = setting("EXECUTABLE")
LABEL = setting("LABEL")
NEEDS_PEAK_TEST = setting("NEEDS_PEAK_TEST", RELEASE) == "1"
OTHER_LABELS = {"com.local.codex-usage", "com.local.glm-usage", "com.local.kimi-usage"} - {LABEL}


class ScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.home = self.base / "home"
        self.apps = self.home / "Applications"
        self.apps.mkdir(parents=True)
        self.bin = self.base / "mock-bin"
        self.bin.mkdir()
        self.log = self.base / "commands.log"
        self.log.write_text("")
        self.state = self.base / "process.state"
        self.unhealthy_marker = self.base / "unhealthy.once"
        self.real_cp = shutil.which("cp")
        self.real_mv = shutil.which("mv")
        self._write_mocks()
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home),
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "MOCK_LOG": str(self.log),
            "MOCK_STATE": str(self.state),
            "MOCK_UNHEALTHY_MARKER": str(self.unhealthy_marker),
            "MOCK_ORIGIN_REPO": REPO,
            "MOCK_APP_NAME": APP_NAME,
            "REAL_CP": self.real_cp,
            "REAL_MV": self.real_mv,
        })

    def tearDown(self):
        self.tmp.cleanup()

    def _mock(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)

    def _write_mocks(self):
        self._mock("curl", r'''
echo "curl $*" >> "$MOCK_LOG"
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
: > "$out"
''')
        self._mock("unzip", r'''
echo "unzip $*" >> "$MOCK_LOG"
if [ "$1" = "-t" ]; then exit 0; fi
dest=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-d" ]; then dest="$2"; shift 2; else shift; fi
done
"$REAL_CP" -R "$MOCK_PAYLOAD" "$dest/"
''')
        self._mock("codesign", r'''
echo "codesign $*" >> "$MOCK_LOG"
if [ "${MOCK_CODESIGN_FAIL:-0}" = 1 ]; then
    case " $* " in *" --sign "*) exit 41 ;; esac
fi
exit 0
''')
        self._mock("launchctl", r'''
echo "launchctl $*" >> "$MOCK_LOG"
case "$1" in
    print) [ "${MOCK_AGENT_ACTIVE:-0}" = 1 ] ;;
    bootout)
        if [ "${MOCK_BOOTOUT_FAIL:-0}" = 1 ]; then exit 42; fi
        rm -f "$MOCK_STATE"
        ;;
    bootstrap)
        if [ "${MOCK_UNHEALTHY_ONCE:-0}" = 1 ] && [ ! -e "$MOCK_UNHEALTHY_MARKER" ]; then
            : > "$MOCK_UNHEALTHY_MARKER"
            exit 0
        fi
        : > "$MOCK_STATE"
        ;;
esac
''')
        self._mock("open", r'''
echo "open $*" >> "$MOCK_LOG"
if [ "$1" = "-R" ]; then exit 0; fi
: > "$MOCK_STATE"
''')
        self._mock("pgrep", '[ -e "$MOCK_STATE" ]\n')
        self._mock("pkill", 'echo "pkill $*" >> "$MOCK_LOG"\nrm -f "$MOCK_STATE"\n')
        self._mock("sleep", "exit 0\n")
        self._mock("cp", r'''
echo "cp $*" >> "$MOCK_LOG"
if [ "${MOCK_CP_FAIL:-0}" = 1 ]; then
    case "$*" in *"/new/"*) exit 43 ;; esac
fi
exec "$REAL_CP" "$@"
''')
        self._mock("mv", r'''
echo "mv $*" >> "$MOCK_LOG"
if [ "${MOCK_MV_SWAP_FAIL:-0}" = 1 ]; then
    case "$1" in *"/new/"*) exit 44 ;; esac
fi
exec "$REAL_MV" "$@"
''')
        self._mock("git", r'''
echo "git $*" >> "$MOCK_LOG"
if [ "$1" = "-C" ]; then shift 2; fi
case "$1" in
    diff|fetch|tag) exit 0 ;;
    push) exit "${MOCK_GIT_PUSH_FAIL:-0}" ;;
    remote) echo "https://github.com/${MOCK_ORIGIN_REPO}.git"; exit 0 ;;
    describe) echo "v9.9.9"; exit 0 ;;
    rev-parse)
        case " $* " in *" -q "*"refs/tags/"*) exit 1 ;; esac
        echo "deadbeef"
        exit 0
        ;;
esac
exit 0
''')
        self._mock("gh", 'echo "gh $*" >> "$MOCK_LOG"\nexit 0\n')
        self._mock("hdiutil", r'''
echo "hdiutil $*" >> "$MOCK_LOG"
if [ "$1" = "create" ]; then : > "${!#}"; fi
exit 0
''')
        self._mock("ditto", 'echo "ditto $*" >> "$MOCK_LOG"\n: > "${!#}"\n')
        self._mock("swiftc", r'''
echo "swiftc $*" >> "$MOCK_LOG"
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
printf '#!/bin/bash\nexit 0\n' > "$out"
chmod +x "$out"
''')

    def make_app(self, parent, version, marker):
        app = parent / APP_NAME
        binary = app / "Contents" / "MacOS" / EXECUTABLE
        resources = app / "Contents" / "Resources"
        binary.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        info = {
            "CFBundleExecutable": EXECUTABLE,
            "CFBundleShortVersionString": version.lstrip("v"),
            "CFBundleVersion": version.lstrip("v"),
            "CUBuildVersion": version,
        }
        with (app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        binary.write_text(r'''#!/bin/bash
case "${1:-}" in
    --self-test)
        echo "self-test" >> "$MOCK_LOG"
        [ "${MOCK_SELF_TEST_FAIL:-0}" = 1 ] && exit 51
        ;;
    --peak-test)
        echo "peak-test" >> "$MOCK_LOG"
        [ "${MOCK_PEAK_TEST_FAIL:-0}" = 1 ] && exit 52
        ;;
esac
exit 0
''')
        binary.chmod(0o755)
        (resources / "marker").write_text(marker)
        return app

    def log_lines(self):
        return self.log.read_text().splitlines()

    def marker(self, app):
        return (app / "Contents" / "Resources" / "marker").read_text()

    def prepare_update(self):
        installed = self.make_app(self.apps, "v1.0.0", "old")
        payload = self.make_app(self.base / "payload", "v2.0.0", "new")
        plist = self.home / "Library" / "LaunchAgents" / f"{LABEL}.plist"
        plist.parent.mkdir(parents=True)
        plist.write_text("test plist")
        self.state.write_text("old process")
        self.env.update({"MOCK_AGENT_ACTIVE": "1", "MOCK_PAYLOAD": str(payload)})
        return installed

    def run_update(self, **overrides):
        env = self.env.copy()
        env.update(overrides)
        return subprocess.run(
            ["bash", str(UPDATE)], env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )

    def test_update_uses_only_own_label_and_cleans_up(self):
        installed = self.prepare_update()
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.marker(installed), "new")
        launch_lines = [line for line in self.log_lines() if line.startswith("launchctl")]
        self.assertTrue(any("bootout" in line for line in launch_lines))
        self.assertTrue(any("bootstrap" in line for line in launch_lines))
        for line in launch_lines:
            self.assertIn(LABEL, line)
            for other in OTHER_LABELS:
                self.assertNotIn(other, line)
        self.assertFalse(any(self.apps.glob(f".{APP_NAME}.update.*")))
        self.assertTrue(self.state.exists())

    def test_staging_failure_preserves_old_app_and_service(self):
        installed = self.prepare_update()
        result = self.run_update(MOCK_CP_FAIL="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.marker(installed), "old")
        self.assertFalse(any("bootout" in line for line in self.log_lines()))
        self.assertFalse(any(line.startswith("pkill") for line in self.log_lines()))
        self.assertTrue(self.state.exists())

    def test_swap_failure_restores_old_app_and_restarts(self):
        installed = self.prepare_update()
        result = self.run_update(MOCK_MV_SWAP_FAIL="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.marker(installed), "old")
        self.assertTrue(self.state.exists())
        self.assertTrue(any("bootstrap" in line for line in self.log_lines()))

    def test_unhealthy_new_app_rolls_back_and_restarts_old_app(self):
        installed = self.prepare_update()
        result = self.run_update(MOCK_UNHEALTHY_ONCE="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.marker(installed), "old")
        self.assertTrue(self.state.exists())
        bootstraps = [line for line in self.log_lines() if "bootstrap" in line]
        self.assertEqual(len(bootstraps), 2)

    def test_bootout_failure_does_not_replace_old_app(self):
        installed = self.prepare_update()
        result = self.run_update(MOCK_BOOTOUT_FAIL="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.marker(installed), "old")
        self.assertFalse(any(line.startswith("mv ") for line in self.log_lines()))

    def prepare_release(self):
        project = self.base / "release-project"
        (project / "scripts").mkdir(parents=True)
        shutil.copy2(RELEASE, project / "scripts" / "release.sh")
        shutil.copy2(UPDATE, project / "scripts" / "update.sh")
        template = self.make_app(self.base / "release-template", "v9.9.9", "release")
        build = project / "build.sh"
        build.write_text(f'''#!/bin/bash
echo "build" >> "$MOCK_LOG"
"$REAL_CP" -R "{template}" "{project / APP_NAME}"
''')
        build.chmod(0o755)
        return project

    def run_release(self, project, **overrides):
        env = self.env.copy()
        env.update(overrides)
        return subprocess.run(
            ["bash", str(project / "scripts" / "release.sh"), "v9.9.9"],
            cwd=project, env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )

    def test_release_tests_and_assets_precede_remote_push(self):
        project = self.prepare_release()
        result = self.run_release(project)
        self.assertEqual(result.returncode, 0, result.stdout)
        lines = self.log_lines()
        push = next(i for i, line in enumerate(lines) if line.startswith("git push"))
        self.assertLess(lines.index("build"), push)
        self.assertLess(lines.index("self-test"), push)
        self.assertLess(next(i for i, line in enumerate(lines) if line.startswith("codesign --verify")), push)
        self.assertLess(next(i for i, line in enumerate(lines) if line.startswith("unzip -t")), push)
        if NEEDS_PEAK_TEST:
            self.assertLess(lines.index("peak-test"), push)
        self.assertTrue(any(line.startswith("gh release create") for line in lines))

    def test_self_test_failure_blocks_push_release_and_cleans_local_tag(self):
        project = self.prepare_release()
        result = self.run_release(project, MOCK_SELF_TEST_FAIL="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        lines = self.log_lines()
        self.assertFalse(any(line.startswith("git push") for line in lines))
        self.assertFalse(any(line.startswith("gh release create") for line in lines))
        self.assertTrue(any("tag -d v9.9.9" in line for line in lines), lines)

    def test_peak_test_failure_blocks_remote_operations(self):
        if not NEEDS_PEAK_TEST:
            self.skipTest("this project has no peak test")
        project = self.prepare_release()
        result = self.run_release(project, MOCK_PEAK_TEST_FAIL="1")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(line.startswith("git push") for line in self.log_lines()))
        self.assertFalse(any(line.startswith("gh release create") for line in self.log_lines()))

    def test_wrong_origin_is_rejected_before_tagging(self):
        project = self.prepare_release()
        result = self.run_release(project, MOCK_ORIGIN_REPO="someone/other-repository")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(line.startswith("git tag") for line in self.log_lines()))
        self.assertFalse(any(line.startswith("git push") for line in self.log_lines()))

    def test_wrong_updater_label_is_rejected_before_tagging(self):
        project = self.prepare_release()
        updater = project / "scripts" / "update.sh"
        updater.write_text(updater.read_text().replace(f'LABEL="{LABEL}"', 'LABEL="com.local.wrong"'))
        result = self.run_release(project)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(line.startswith("git tag") for line in self.log_lines()))
        self.assertFalse(any(line.startswith("git push") for line in self.log_lines()))

    def test_codesign_failure_blocks_build(self):
        project = self.base / "build-project"
        (project / "scripts").mkdir(parents=True)
        shutil.copy2(BUILD, project / "build.sh")
        shutil.copy2(ROOT / "Info.plist", project / "Info.plist")
        shutil.copy2(ROOT / "AppIcon.icns", project / "AppIcon.icns")
        shutil.copy2(UPDATE, project / "scripts" / "update.sh")
        (project / f"{EXECUTABLE}.swift").write_text("// swiftc is mocked\n")
        result = subprocess.run(
            ["bash", str(project / "build.sh")], cwd=project,
            env={**self.env, "MOCK_CODESIGN_FAIL": "1"}, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("== 完成:", result.stdout)
        self.assertTrue(any("--sign" in line for line in self.log_lines()))


if __name__ == "__main__":
    unittest.main()
