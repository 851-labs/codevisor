import importlib.util
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cleanup", Path(__file__).with_name("cleanup.py"))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runner = self.root / "actions-runner"
        self.runner.mkdir()
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.file = self.cache / ("a" * 128 + ".body")
        self.file.write_bytes(b"cached download")
        self.other = self.cache / "keep-me"
        self.other.write_text("unrecognized data")
        self.targets = [(self.cache, cleanup.FFMPEG_FILE)]
        self.listener = [(123, str(self.runner / "bin/Runner.Listener"))]

    def test_report_does_not_delete_or_pause(self):
        with patch.object(cleanup.os, "kill") as kill:
            report = cleanup.clean(self.targets, False, self.runner)
        self.assertEqual(report["files"], 1)
        self.assertTrue(self.file.exists())
        kill.assert_not_called()

    def apply(self, entries=None, open_files=""):
        with patch.object(cleanup, "processes", side_effect=entries or [self.listener] * 2), \
             patch.object(cleanup.os, "kill") as kill, \
             patch.object(cleanup.subprocess, "run", side_effect=[
                 subprocess.CompletedProcess([], 0, "T", ""),
                 subprocess.CompletedProcess([], 0, open_files, ""),
             ]):
            report = cleanup.clean(self.targets, True, self.runner)
        self.assertEqual(kill.call_args_list[0].args, (123, signal.SIGSTOP))
        self.assertEqual(kill.call_args_list[-1].args, (123, signal.SIGCONT))
        return report

    def test_idle_cleanup_preserves_unrecognized_files(self):
        report = self.apply()
        self.assertFalse(self.file.exists())
        self.assertTrue(self.other.exists())
        self.assertEqual(report["unrecognized_entries_preserved"], 1)

    def test_active_job_is_never_paused(self):
        with patch.object(cleanup, "processes", return_value=[
            *self.listener, (124, str(self.runner / "bin/Runner.Worker")),
        ]), patch.object(cleanup.os, "kill") as kill:
            with self.assertRaises(cleanup.Busy):
                cleanup.clean(self.targets, True, self.runner)
        self.assertTrue(self.file.exists())
        kill.assert_not_called()

    def test_job_assignment_race_resumes_listener_without_deleting(self):
        with patch.object(cleanup, "processes", side_effect=[
            self.listener, [*self.listener, (124, str(self.runner / "bin/Runner.Worker"))],
        ]), patch.object(cleanup.os, "kill") as kill, \
             patch.object(cleanup.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 0, "T", "")):
            with self.assertRaises(cleanup.Busy):
                cleanup.clean(self.targets, True, self.runner)
        self.assertTrue(self.file.exists())
        self.assertEqual(kill.call_args_list[-1].args, (123, signal.SIGCONT))

    def test_open_files_block_cleanup_and_listener_resumes(self):
        with patch.object(cleanup, "processes", side_effect=[self.listener] * 2), \
             patch.object(cleanup.os, "kill") as kill, \
             patch.object(cleanup.subprocess, "run", side_effect=[
                 subprocess.CompletedProcess([], 0, "T", ""),
                 subprocess.CompletedProcess([], 0, "n" + str(self.file) + "\n", ""),
             ]):
            with self.assertRaises(cleanup.Busy):
                cleanup.clean(self.targets, True, self.runner)
        self.assertTrue(self.file.exists())
        self.assertEqual(kill.call_args_list[-1].args, (123, signal.SIGCONT))

    def test_symlinks_are_preserved(self):
        linked = self.cache / ("b" * 128 + ".body")
        linked.symlink_to(self.other)
        self.apply()
        self.assertTrue(linked.is_symlink())
        self.assertTrue(self.other.exists())

    def test_deletion_error_resumes_listener(self):
        with patch.object(cleanup, "processes", side_effect=[self.listener] * 2), \
             patch.object(cleanup.os, "kill") as kill, \
             patch.object(cleanup.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 0, "T", "")), \
             patch.object(cleanup, "require_closed"), \
             patch.object(Path, "unlink", side_effect=PermissionError("cannot delete")):
            with self.assertRaises(PermissionError):
                cleanup.clean(self.targets, True, self.runner)
        self.assertTrue(self.file.exists())
        self.assertEqual(kill.call_args_list[-1].args, (123, signal.SIGCONT))

    def test_symlinked_directory_is_rejected(self):
        linked = self.root / "linked-cache"
        linked.symlink_to(self.cache, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            cleanup.inventory([(linked, cleanup.FFMPEG_FILE)])
        self.assertTrue(self.file.exists())

    def test_database_and_sidecars_are_selected(self):
        for suffix in (".db", ".db-wal", ".db-shm"):
            (self.cache / ("00065070-764C-4A80-9923-E4D1F7F5B556" + suffix)).touch()
        files, _ = cleanup.inventory([(self.cache, cleanup.SQLITE_FILE)])
        self.assertEqual(len(files), 3)


if __name__ == "__main__":
    unittest.main()
