import os
import shutil
import tempfile
import unittest

import runner_janitor as janitor

NOW = 1_794_000_000.0
DAY = janitor.DAY_SECONDS
GB = janitor.GB


class FakeDisk:
    def __init__(self, free, sizes):
        self.base = free * GB
        self.sizes = sizes

    def free(self):
        freed = sum(size for path, size in self.sizes.items() if not os.path.lexists(path))
        return self.base + freed * GB


class RunnerFixture:
    def __init__(self, root):
        self.home = os.path.join(root, "home")
        self.runner = os.path.join(self.home, "actions-runner")
        self.workspace = self.path("actions-runner/_work/codevisor/codevisor")
        self.log = []

    def path(self, relative):
        return os.path.join(self.home, relative)

    def file(self, relative, days_ago, read_days_ago=None):
        path = self.path(relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write("x")
        self.age(relative, days_ago, read_days_ago)
        return path

    def age(self, relative, days_ago, read_days_ago=None):
        modified = NOW - days_ago * DAY
        read = NOW - (days_ago if read_days_ago is None else read_days_ago) * DAY
        os.utime(self.path(relative), (read, modified))

    def age_tree(self, relative, days_ago):
        for directory, _names, _files in sorted(os.walk(self.path(relative)), reverse=True):
            modified = NOW - days_ago * DAY
            os.utime(directory, (modified, modified))

    def clean(self, disk):
        layout = janitor.Layout(self.home, self.runner, [self.workspace])
        return janitor.clean(layout, NOW, disk.free, self.log.append)


class CleanTests(unittest.TestCase):
    def setUp(self):
        root = tempfile.mkdtemp(prefix="runner-janitor-")
        self.addCleanup(shutil.rmtree, root)
        self.runner = RunnerFixture(root)

    def test_low_disk_removes_least_recently_used_caches_until_the_target(self):
        runner = self.runner
        workspace = runner.file("actions-runner/_work/codevisor/codevisor/README.md", 10)
        other = runner.file("actions-runner/_work/other/other/README.md", 3)
        net = runner.file(".codevisor-development/artifacts/net/aaaaaaaaaaaaaaaa/x", 2)
        node = runner.file("actions-runner/_work/_tool/node/24.0.0/arm64/bin/node", 10, 0)
        system = runner.file("Library/Caches/com.apple.thing/data", 10)
        for tree, days in (("actions-runner/_work", 10), (".codevisor-development", 2)):
            runner.age_tree(tree, days)
        runner.age_tree("actions-runner/_work/other", 3)
        disk = FakeDisk(25, {os.path.dirname(other): 10, os.path.dirname(net): 10})

        status = runner.clean(disk)

        self.assertEqual(status, 0)
        self.assertFalse(os.path.exists(other))
        self.assertFalse(os.path.exists(net))
        for kept in (workspace, node, system):
            self.assertTrue(os.path.exists(kept), kept)

    def test_caches_unused_for_two_weeks_and_week_old_runner_logs_go_even_with_room(self):
        runner = self.runner
        stale = runner.file("Library/Caches/old-tool/blob", 15)
        recent = runner.file("Library/Caches/new-tool/blob", 13)
        old_log = runner.file("actions-runner/_diag/Worker_old.log", 8)
        new_log = runner.file("actions-runner/_diag/Worker_new.log", 6)
        runner.age_tree("Library/Caches/old-tool", 15)
        runner.age_tree("Library/Caches/new-tool", 13)

        status = runner.clean(FakeDisk(100, {}))

        self.assertEqual(status, 0)
        self.assertEqual([os.path.exists(path) for path in (stale, old_log)], [False, False])
        self.assertEqual([os.path.exists(path) for path in (recent, new_log)], [True, True])

    def test_job_fails_when_nothing_left_to_remove_frees_enough(self):
        status = self.runner.clean(FakeDisk(10, {}))

        self.assertEqual(status, 1)
        self.assertIn("jobs need 20.0 GB", self.runner.log[-1])


if __name__ == "__main__":
    unittest.main()
