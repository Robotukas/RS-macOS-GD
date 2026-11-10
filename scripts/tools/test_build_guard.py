"""Tests for the build guard in scripts/build-xcode.sh (remap step 2, S1(c)).

Every test works in a temporary git repository that holds a copy of the script, a few fake driver sources and fake
`systemextensionsctl`, `xcodegen` and `xcodebuild` programs on PATH. The real project, the real Xcode and the real
system extensions are never touched; nothing is installed."""
import hashlib
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SCRIPT = os.path.join(ROOT, "scripts", "build-xcode.sh")

with open(SCRIPT) as f:
    SCRIPT_TEXT = f.read()
DEXT_ID = re.search(r"^DEXT_ID=(\S+);", SCRIPT_TEXT, re.M).group(1)
AGENT_NAME = re.search(r"^AGENT=~/Library/LaunchAgents/(\S+)$", SCRIPT_TEXT, re.M).group(1)

PROJECT_YML = """name: Demo
targets:
  App:
    type: application
    info: {properties: {Version: $(CURRENT_PROJECT_VERSION)}}
  GDHubVirtualHID:
    type: driver-extension
    # a comment inside the block
    sources:
      - Dext/GDHubVirtualHID
    settings:
      base: {CODE_SIGN_STYLE: Automatic}

  Other:
    type: tool
"""


def sysext(*entries):
    """`systemextensionsctl list` as the guard reads it: entries are (build, state)."""
    out = ["1 extension(s)", "--- com.apple.system_extension.driver_extension", "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]"]
    out.append("*\t*\tTEAMX\tcom.example.other.driver (1.0/1)\tOther driver\t[activated enabled]")
    for build, state in entries:
        out.append("*\t*\tTEAMX\t%s (0.1.0/%s)\tVirtual HID\t[%s]" % (DEXT_ID, build, state))
    return "\n".join(out) + "\n"


class Repo:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "repo")
        self.home = os.path.join(self.tmp.name, "home")
        self.bin = os.path.join(self.tmp.name, "fakebin")
        for d in ("scripts", "Dext/GDHubVirtualHID", "Shared", "Xcode", self.home, self.bin):
            os.makedirs(d if os.path.isabs(d) else os.path.join(self.root, d), exist_ok=True)
        shutil.copy(SCRIPT, os.path.join(self.root, "scripts", "build-xcode.sh"))
        self.write("Dext/GDHubVirtualHID/a.cpp", "int a;\n")
        self.write("Shared/b.c", "int b;\n")
        self.write("project.yml", PROJECT_YML)
        self.sysext_file = os.path.join(self.tmp.name, "sysext.txt")
        self.fake_log = os.path.join(self.tmp.name, "fake.log")
        self.set_sysext(sysext((24, "activated enabled")))
        self.fake("systemextensionsctl", 'cat "$FAKE_SYSEXT_FILE"')
        self.fake("xcodegen", "exit 0")
        self.fake("xcodebuild", """
echo "xcodebuild $*" >> "$FAKE_LOG"
dd=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in -derivedDataPath) dd="$2";; -configuration) cfg="$2";; esac
  shift
done
echo "$dd" > "$FAKE_LOG.dd"
if [ -n "$FAKE_XCODEBUILD_FAIL" ]; then echo "error: fake compile error"; exit 65; fi
mkdir -p "$dd/Build/Products/$cfg/GDHub.app/Contents/Library/SystemExtensions"
echo built > "$dd/Build/Products/$cfg/GDHub.app/marker"
""")
        self.git("init", "-q")
        self.commit("first")

    def close(self):
        self.tmp.cleanup()

    def path(self, rel):
        return os.path.join(self.root, rel)

    def write(self, rel, text):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)

    def read(self, rel):
        try:
            with open(self.path(rel)) as f:
                return f.read().strip()
        except FileNotFoundError:
            return None

    def fake(self, name, body):
        p = os.path.join(self.bin, name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\n" + body + "\n")
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)

    def set_sysext(self, text):
        with open(self.sysext_file, "w") as f:
            f.write(text)

    def env(self, **extra):
        env = {"PATH": self.bin + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": self.home,
               "FAKE_SYSEXT_FILE": self.sysext_file, "FAKE_LOG": self.fake_log,
               "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test", "GIT_COMMITTER_NAME": "test",
               "GIT_COMMITTER_EMAIL": "test", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
        env.update(extra)
        return env

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env(), check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, msg):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)
        return self.git("rev-parse", "HEAD")

    def run(self, *args, verify_skipped=True, **extra):
        env = self.env(**extra)
        if verify_skipped:
            env["GDHUB_BUILD_TEST_SKIP_VERIFY"] = "1"
        p = subprocess.run(["zsh", "scripts/build-xcode.sh", *args], cwd=self.root, env=env, capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr

    def fake_log_text(self):
        try:
            with open(self.fake_log) as f:
                return f.read()
        except FileNotFoundError:
            return ""

    def agent(self):
        d = os.path.join(self.home, "Library", "LaunchAgents")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, AGENT_NAME), "w") as f:
            f.write("<plist/>")


def reference_hash(root):
    """The hash the guard defines: tracked files of Dext/ and Shared/ sorted by path (path, size, bytes), then the
    GDHubVirtualHID block of project.yml."""
    files = subprocess.run(["git", "ls-files", "-z", "--", "Dext", "Shared"], cwd=root, capture_output=True, check=True).stdout.split(b"\0")
    h = hashlib.sha256()
    for p in sorted(x for x in files if x):
        with open(os.path.join(root, p.decode()), "rb") as f:
            data = f.read()
        h.update(b"F %s %d\n" % (p, len(data)) + data + b"\n")
    with open(os.path.join(root, "project.yml")) as f:
        lines = f.read().split("\n")
    start = lines.index("  GDHubVirtualHID:")
    block = [lines[start]]
    for l in lines[start + 1:]:
        body = l.lstrip(" ")
        if body and not body.startswith("#") and len(l) - len(body) <= 2:
            break
        block.append(l)
    while block and not block[-1].strip():
        block.pop()
    h.update(b"P\n" + ("\n".join(block) + "\n").encode())
    return h.hexdigest()


class BuildGuardTest(unittest.TestCase):
    def setUp(self):
        self.r = Repo()
        self.addCleanup(self.r.close)
        self.first = self.r.git("rev-parse", "HEAD")

    def seed(self, build=24):
        code, out = self.r.run("--seed-source-hash", str(build), self.first)
        self.assertEqual(code, 0, out)

    # --- seeding

    def test_seeding_writes_the_number_and_the_hash_of_the_commit(self):
        self.seed()
        self.assertEqual(self.r.read("Xcode/dext-source.hash"), "24 " + reference_hash(self.r.root))
        self.assertEqual(self.r.read("Xcode/build-number"), "24")

    def test_the_hash_ignores_the_rest_of_project_yml_and_other_folders(self):
        before = reference_hash(self.r.root)
        self.r.write("project.yml", PROJECT_YML.replace("type: tool", "type: framework").replace("Version:", "Other:"))
        self.r.write("Sources/x.swift", "let x = 1\n")
        self.r.commit("elsewhere")
        self.assertEqual(reference_hash(self.r.root), before)
        self.seed()                                           # still the sources of the first commit
        self.assertEqual(self.r.read("Xcode/dext-source.hash"), "24 " + before)

    def test_seeding_refuses_sources_that_differ_from_the_commit(self):
        self.r.write("Shared/b.c", "int b = 2;\n")
        self.r.commit("driver change")
        code, out = self.r.run("--seed-source-hash", "24", self.first)
        self.assertNotEqual(code, 0)
        self.assertIn("seeding refused", out)
        self.assertIsNone(self.r.read("Xcode/dext-source.hash"))

    def test_seeding_refuses_uncommitted_and_untracked_changes_under_the_driver_folders(self):
        self.r.write("Dext/GDHubVirtualHID/a.cpp", "int a = 2;\n")
        code, out = self.r.run("--seed-source-hash", "24", self.first)
        self.assertNotEqual(code, 0, out)
        self.r.git("checkout", "--", "Dext")
        self.r.write("Shared/new.c", "int n;\n")
        code, out = self.r.run("--seed-source-hash", "24", self.first)
        self.assertNotEqual(code, 0, out)
        self.assertIsNone(self.r.read("Xcode/dext-source.hash"))

    def test_seeding_refuses_a_changed_driver_target_block(self):
        self.r.write("project.yml", PROJECT_YML.replace("Automatic", "Manual"))
        self.r.commit("block change")
        code, out = self.r.run("--seed-source-hash", "24", self.first)
        self.assertNotEqual(code, 0)
        self.assertIn("GDHubVirtualHID block", out)

    def test_seeding_needs_a_number_and_a_real_commit(self):
        self.assertNotEqual(self.r.run("--seed-source-hash")[0], 0)
        self.assertNotEqual(self.r.run("--seed-source-hash", "x24", self.first)[0], 0)
        self.assertNotEqual(self.r.run("--seed-source-hash", "24", "no-such-commit")[0], 0)
        self.assertIsNone(self.r.read("Xcode/dext-source.hash"))

    # --- --same-build

    def test_same_build_refuses_when_the_hash_file_is_missing(self):
        self.r.write("Xcode/build-number", "24\n")
        code, out = self.r.run("--same-build", "--no-install")
        self.assertNotEqual(code, 0)
        self.assertIn("--seed-source-hash 24", out)
        self.assertEqual(self.r.fake_log_text(), "", "nothing was built")

    def test_same_build_refuses_when_the_hash_file_is_for_another_number(self):
        self.seed(23)
        self.r.write("Xcode/build-number", "24\n")
        code, out = self.r.run("--same-build", "--no-install")
        self.assertNotEqual(code, 0)
        self.assertIn("for build 23", out)
        self.assertEqual(self.r.fake_log_text(), "")

    def test_same_build_refuses_when_the_driver_sources_changed(self):
        self.seed()
        self.r.write("Dext/GDHubVirtualHID/a.cpp", "int a = 3;\n")
        self.r.git("add", "-A")                                # tracked, even committed: the hash still differs
        code, out = self.r.run("--same-build", "--no-install")
        self.assertNotEqual(code, 0)
        self.assertIn("not the ones build 24 was built from", out)
        self.assertEqual(self.r.fake_log_text(), "")
        self.assertEqual(self.r.read("Xcode/build-number"), "24")

    def test_same_build_refuses_a_changed_driver_block_of_project_yml_but_not_other_edits(self):
        self.seed()
        self.r.write("project.yml", PROJECT_YML.replace("Version:", "Other:"))       # the app target: fine
        code, out = self.r.run("--same-build", "--no-install")
        self.assertEqual(code, 0, out)
        self.r.write("project.yml", PROJECT_YML.replace("Automatic", "Manual"))
        code, out = self.r.run("--same-build", "--no-install")
        self.assertNotEqual(code, 0)

    def test_same_build_refuses_an_untracked_driver_file(self):
        self.seed()
        self.r.write("Dext/GDHubVirtualHID/extra.cpp", "int c;\n")
        code, out = self.r.run("--same-build", "--no-install")
        self.assertNotEqual(code, 0)
        self.assertIn("untracked", out)

    def test_same_build_refuses_when_the_activated_enabled_build_differs(self):
        self.seed(25)
        self.r.write("Xcode/build-number", "25\n")
        # build 25 is listed but 24 is the one that is activated and enabled: the highest listed number is not enough
        self.r.set_sysext(sysext((24, "activated enabled"), (25, "terminated waiting to uninstall on reboot")))
        code, out = self.r.run("--same-build", "--no-install")
        self.assertNotEqual(code, 0)
        self.assertIn("activated enabled driver is build 24", out)
        self.assertEqual(self.r.fake_log_text(), "")

    def test_same_build_refuses_when_no_build_is_activated_and_enabled(self):
        self.seed()
        self.r.set_sysext(sysext((24, "activated waiting for user")))
        code, out = self.r.run("--same-build", "--no-install")
        self.assertNotEqual(code, 0)
        self.assertIn("no activated enabled build", out)

    def test_same_build_passes_for_unchanged_sources_at_the_enabled_build(self):
        self.seed()
        digest = reference_hash(self.r.root)
        code, out = self.r.run("--same-build", "--no-install", "--release")
        self.assertEqual(code, 0, out)
        self.assertIn("built build 24 (Release)", out)
        log = self.r.fake_log_text()
        self.assertIn("CURRENT_PROJECT_VERSION=24", log)
        self.assertIn("GDHUB_DEXT_SOURCE_HASH=" + digest, log)
        self.assertEqual(self.r.read("Xcode/dext-source.hash"), "24 " + digest)
        self.assertEqual(self.r.read("Xcode/build-number"), "24")

    def test_same_build_passes_with_the_engine_agent_installed(self):
        self.seed()
        self.r.agent()
        code, out = self.r.run("--same-build", "--no-install")
        self.assertEqual(code, 0, out)

    # --- bumps and failures

    def test_a_bump_rewrites_the_number_and_the_hash_after_a_successful_build(self):
        self.seed()
        self.r.write("Shared/b.c", "int b = 4;\n")
        self.r.commit("driver change")
        digest = reference_hash(self.r.root)
        code, out = self.r.run("--no-install")
        self.assertEqual(code, 0, out)
        self.assertIn("built build 25", out)
        self.assertEqual(self.r.read("Xcode/build-number"), "25")
        self.assertEqual(self.r.read("Xcode/dext-source.hash"), "25 " + digest)

    def test_a_bump_is_refused_while_the_engine_agent_is_installed(self):
        self.seed()
        self.r.agent()
        code, out = self.r.run("--no-install")
        self.assertEqual(code, 2)
        self.assertIn("engine-agent.sh uninstall", out)

    def test_a_failed_build_leaves_the_number_and_the_hash_as_they_were(self):
        self.seed()
        seeded = self.r.read("Xcode/dext-source.hash")
        self.r.write("Shared/b.c", "int b = 5;\n")
        self.r.commit("driver change")
        code, out = self.r.run("--no-install", FAKE_XCODEBUILD_FAIL="1")
        self.assertNotEqual(code, 0)
        self.assertIn("fake compile error", out)
        self.assertEqual(self.r.read("Xcode/build-number"), "24")
        self.assertEqual(self.r.read("Xcode/dext-source.hash"), seeded)

    def test_the_post_build_checks_cannot_be_skipped_for_an_install(self):
        self.seed()
        code, out = self.r.run("--same-build")                       # no --no-install, hook set
        self.assertEqual(code, 2)
        self.assertIn("needs --no-install", out)
        self.assertEqual(self.r.fake_log_text(), "")

    # --- --check

    def test_check_builds_release_in_a_scratch_folder_and_records_nothing(self):
        self.r.write("Xcode/build-number", "24\n")                   # no hash file at all: --check does not mind
        self.r.agent()                                              # nor a running engine agent
        code, out = self.r.run("--check")
        self.assertEqual(code, 0, out)
        self.assertIn("check passed", out)
        log = self.r.fake_log_text()
        self.assertIn("-configuration Release", log)
        self.assertIn("-derivedDataPath .xcodebuild-check", log)
        self.assertIn("CURRENT_PROJECT_VERSION=24", log)
        self.assertEqual(self.r.read("Xcode/build-number"), "24")
        self.assertIsNone(self.r.read("Xcode/dext-source.hash"))
        self.assertFalse(os.path.exists(self.r.path(".xcodebuild-check/Build/Products/Release/GDHub.app")), "the built app is deleted")
        self.assertFalse(os.path.exists(self.r.path(".xcodebuild")), "the real build folder is untouched")

    def test_check_leaves_a_seeded_hash_and_the_number_alone_with_changed_sources(self):
        self.seed()
        seeded = self.r.read("Xcode/dext-source.hash")
        self.r.write("Shared/b.c", "int b = 6;\n")
        self.r.git("add", "-A")
        code, out = self.r.run("--check")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.r.read("Xcode/dext-source.hash"), seeded)
        self.assertEqual(self.r.read("Xcode/build-number"), "24")

    def test_check_uses_the_highest_known_number_and_does_not_bump(self):
        self.r.write("Xcode/build-number", "24\n")
        self.r.set_sysext(sysext((24, "activated enabled"), (25, "terminated waiting to uninstall on reboot")))
        code, out = self.r.run("--check")
        self.assertEqual(code, 0, out)
        self.assertIn("CURRENT_PROJECT_VERSION=25", self.r.fake_log_text())
        self.assertEqual(self.r.read("Xcode/build-number"), "24")

    def test_check_with_untracked_driver_files_still_compiles(self):
        self.r.write("Shared/new.c", "int n;\n")
        code, out = self.r.run("--check")
        self.assertEqual(code, 0, out)
        self.assertIn("GDHUB_DEXT_SOURCE_HASH=unhashed", self.r.fake_log_text())

    def test_check_deletes_the_app_after_a_failed_build_too(self):
        code, out = self.r.run("--check", FAKE_XCODEBUILD_FAIL="1")
        self.assertNotEqual(code, 0)
        self.assertFalse(os.path.exists(self.r.path(".xcodebuild-check/Build/Products/Release/GDHub.app")))

    def test_check_does_not_combine_with_same_build(self):
        self.seed()
        code, out = self.r.run("--check", "--same-build")
        self.assertEqual(code, 2)
        self.assertEqual(self.r.fake_log_text(), "")


class RealScriptTest(unittest.TestCase):
    def test_the_script_parses_and_documents_its_modes(self):
        subprocess.run(["zsh", "-n", SCRIPT], check=True)
        for mode in ("--check", "--seed-source-hash", "--same-build"):
            self.assertIn(mode, SCRIPT_TEXT)

    def test_the_build_number_is_written_only_after_the_build_and_the_checks(self):
        write = SCRIPT_TEXT.index('print -r -- $BUILD > "$NUMFILE"')
        self.assertGreater(write, SCRIPT_TEXT.index("if [[ $SKIP_VERIFY != 1 ]]; then verify_build; fi"))
        self.assertGreater(write, SCRIPT_TEXT.index("GDHUB_DEXT_SOURCE_HASH=$HASH build"))
        self.assertEqual(SCRIPT_TEXT.count('> "$NUMFILE"'), 1, "nothing writes the number before the build")


if __name__ == "__main__":
    unittest.main()
