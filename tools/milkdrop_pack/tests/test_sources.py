import os
import shutil
import subprocess
import unittest
from unittest import mock

from milkpack import sources

from .helpers import tmpdir, write

GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_COUNT": "2",
    "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always",
    "GIT_CONFIG_KEY_1": "init.defaultBranch", "GIT_CONFIG_VALUE_1": "main",
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.test",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.test",
}


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


class GitCheckoutTest(unittest.TestCase):
    """A parent repo with a submodule, both served over file://."""

    def setUp(self):
        patcher = mock.patch.dict(os.environ, GIT_ENV)
        patcher.start()
        self.addCleanup(patcher.stop)
        d = tmpdir(self)
        sub = os.path.join(d, "eval")
        git("init", "-q", sub)
        write(os.path.join(sub, "eval.c"), "int x;\n")
        git("-C", sub, "add", ".")
        git("-C", sub, "commit", "-q", "-m", "eval")
        self.sub_commit = git("-C", sub, "rev-parse", "HEAD")
        parent = os.path.join(d, "projectm")
        git("init", "-q", parent)
        write(os.path.join(parent, "CMakeLists.txt"), "project(x)\n")
        git("-C", parent, "submodule", "add", "-q", "file://" + sub, "vendor/projectm-eval")
        git("-C", parent, "add", ".")
        git("-C", parent, "commit", "-q", "-m", "parent")
        self.repo = "file://" + parent
        self.commit = git("-C", parent, "rev-parse", "HEAD")
        self.dest = os.path.join(d, "checkout")
        self.log = os.path.join(d, "log")
        self.eval_dir = os.path.join(self.dest, "vendor", "projectm-eval")

    def checkout(self):
        return sources.git_checkout(self.repo, self.commit, self.dest, self.log, ["vendor/projectm-eval"])

    def assert_complete(self):
        self.assertEqual(git("-C", self.dest, "rev-parse", "HEAD"), self.commit)
        self.assertTrue(sources.submodule_ok(self.dest, "vendor/projectm-eval"))
        with open(os.path.join(self.eval_dir, "eval.c")) as f:
            self.assertEqual(f.read(), "int x;\n")

    def test_fresh_checkout_has_the_submodule(self):
        self.checkout()
        self.assert_complete()

    def test_reuse_initialises_a_submodule_an_interrupted_run_skipped(self):
        # Interrupted after the parent's checkout, before `submodule update`.
        os.makedirs(self.dest)
        git("-C", self.dest, "init", "-q")
        git("-C", self.dest, "fetch", "-q", "--depth", "1", self.repo, self.commit)
        git("-C", self.dest, "checkout", "-q", "--force", "FETCH_HEAD")
        self.assertFalse(sources.submodule_ok(self.dest, "vendor/projectm-eval"))
        self.checkout()
        self.assert_complete()

    def test_reuse_repairs_a_half_made_submodule(self):
        self.checkout()
        # A clone cut off midway: the module's git dir is gone.
        shutil.rmtree(os.path.join(self.dest, ".git", "modules", "vendor", "projectm-eval"))
        self.assertFalse(sources.submodule_ok(self.dest, "vendor/projectm-eval"))
        self.checkout()
        self.assert_complete()

    def test_reuse_restores_a_moved_or_dirty_submodule(self):
        self.checkout()
        write(os.path.join(self.eval_dir, "eval.c"), "int y;\n")
        self.assertFalse(sources.submodule_ok(self.dest, "vendor/projectm-eval"))
        self.checkout()
        self.assert_complete()


if __name__ == "__main__":
    unittest.main()
