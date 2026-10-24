"""Exercise release safeguards with fake build tools and a local Git repository."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("zsh") and shutil.which("git"), "Requires zsh and git")
class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="iphone use release ")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.repo = self.directory / "repo"
        self.tools = self.directory / "tools"
        self.repo.mkdir()
        self.tools.mkdir()
        self.events = self.directory / "events.jsonl"
        self.state = self.directory / "draft"
        (self.repo / "scripts").mkdir()
        shutil.copy(ROOT / "scripts/release.sh", self.repo / "scripts/release.sh")
        (self.repo / ".gitignore").write_text("build/\n")
        self.executable(self.repo / "scripts/build-app.sh", """#!/bin/zsh
set -eu
mkdir -p build/iPhoneUseReviewed.app/Contents/MacOS
print -r -- "$APP_VERSION $BUILD_ARCH $CODESIGN_IDENTITY" > build/version.txt
print 'fake executable' > build/iPhoneUseReviewed.app/Contents/MacOS/iphone-use
""")
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.git("tag", "v0.2.0")
        self.env = dict(
            os.environ, PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
            GITHUB_REPOSITORY="example/iphone-use", RELEASE_TEST_EVENTS=str(self.events),
            RELEASE_TEST_STATE=str(self.state), RELEASE_TEST_COMMIT=self.commit,
            RELEASE_TEST_EXISTING="", RELEASE_TEST_FAIL="", CODESIGN_IDENTITY="-",
        )
        self.executable(self.tools / "uname", "#!/bin/sh\necho Darwin\n")
        stub = "#!" + sys.executable + "\n" + '''
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["RELEASE_TEST_EVENTS"], "a") as events:
    events.write(json.dumps([name, *args]) + "\\n")
if os.environ["RELEASE_TEST_FAIL"] == name:
    sys.exit(1)
if name == "ditto":
    Path(args[-1]).write_bytes(b"fake archive")
elif name == "gh":
    state = Path(os.environ["RELEASE_TEST_STATE"])
    if args[0] == "api":
        if "--paginate" in args:
            print(os.environ["RELEASE_TEST_EXISTING"], end="")
        else:
            print(os.environ["RELEASE_TEST_COMMIT"])
    elif args[:2] == ["release", "create"]:
        state.write_text("true")
    elif args[:2] == ["release", "edit"]:
        state.write_text("false")
    elif args[:2] == ["release", "view"]:
        if "isDraft" in args:
            print(state.read_text() if state.exists() else os.environ["RELEASE_TEST_EXISTING"])
        else:
            print("https://github.com/example/iphone-use/releases/tag/" + args[2])
'''
        for name in ("swift", "python3", "codesign", "ditto", "lipo", "gh"):
            self.executable(self.tools / name, stub)

    def executable(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True)

    def run_release(self, tag="v0.2.0", publish=True):
        args = ["zsh", "scripts/release.sh", tag]
        if publish:
            args.append("--publish")
        return subprocess.run(args, cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=20)

    def calls(self, name):
        if not self.events.exists():
            return []
        return [event for line in self.events.read_text().splitlines()
                if (event := json.loads(line))[0] == name]

    def release_writes(self):
        return [event[2] for event in self.calls("gh")
                if event[1] == "release" and event[2] in ("create", "upload", "edit")]

    def test_local_package_does_not_contact_github(self):
        result = self.run_release(publish=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls("gh"), [])
        self.assertTrue((self.repo / "build/releases/v0.2.0/SHA256SUMS.txt").is_file())

    def test_publishes_only_after_uploading_a_draft(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.release_writes(), ["create", "upload", "edit"])
        self.assertEqual(self.state.read_text(), "false")
        self.assertEqual((self.repo / "build/version.txt").read_text().strip(), "0.2.0 universal -")

    def test_prerelease_uses_numeric_bundle_version(self):
        self.git("tag", "v0.3.0-beta.1")
        result = self.run_release("v0.3.0-beta.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.repo / "build/version.txt").read_text().strip(), "0.3.0 universal -")
        edit = next(event for event in self.calls("gh") if event[1:3] == ["release", "edit"])
        self.assertIn("--prerelease=true", edit)

    def test_resumes_an_unfinished_draft(self):
        self.env["RELEASE_TEST_EXISTING"] = "true"
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.release_writes(), ["upload", "edit"])

    def test_does_not_overwrite_a_published_release(self):
        self.env["RELEASE_TEST_EXISTING"] = "false"
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already published", result.stderr)
        self.assertEqual(self.release_writes(), [])
        self.assertEqual(self.calls("swift"), [])

    def test_rejects_dirty_or_mismatched_source(self):
        (self.repo / "uncommitted.txt").write_text("local change")
        result = self.run_release()
        self.assertIn("clean checkout", result.stderr)
        self.assertNotEqual(result.returncode, 0)
        (self.repo / "uncommitted.txt").unlink()
        self.env["RELEASE_TEST_COMMIT"] = "0" * 40
        result = self.run_release()
        self.assertIn("remote tag does not match", result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.release_writes(), [])

    def test_failing_build_or_validation_never_publishes(self):
        for failing_tool in ("swift", "lipo", "codesign", "python3", "ditto"):
            with self.subTest(tool=failing_tool):
                self.env["RELEASE_TEST_FAIL"] = failing_tool
                result = self.run_release()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.release_writes(), [])

    def test_failed_upload_leaves_the_release_unpublished(self):
        # A failed gh upload is simulated after the draft has been created.
        stub = (self.tools / "gh").read_text()
        stub = stub.replace('elif args[:2] == ["release", "edit"]:',
                            'elif args[:2] == ["release", "upload"]:\n        sys.exit(1)\n'
                            '    elif args[:2] == ["release", "edit"]:')
        self.executable(self.tools / "gh", stub)
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.release_writes(), ["create", "upload"])
        self.assertEqual(self.state.read_text(), "true")

    def test_rejects_invalid_version_before_running_tools(self):
        for tag in ("main", "v01.2.3", "v1.2", "v1.2.3/other", "v1.2.3-", "v1.2.3;echo bad"):
            with self.subTest(tag=tag):
                result = self.run_release(tag)
                self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls("swift"), [])
        self.assertEqual(self.calls("gh"), [])
