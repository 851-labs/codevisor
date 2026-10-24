# CI runner leak cleanup

The same procedure applies to `croissant` (`croissant@croissants-mac-mini`) and
`tamales` (`tamale@tamales-mac-mini`). It removes the accumulated files from the
FFmpeg signed-URL cache bug and health tests' temporary SQLiteData databases.
Codevisor #835 and lil.tech #450 prevent those leaks in subsequent builds from main.

Copy `cleanup.py` to `~/runner-maintenance/cleanup.py` on each runner. Run it with
`python3 ~/runner-maintenance/cleanup.py` for a report, then with
`--apply --wait-idle 1800` to wait up to 30 minutes for an idle boundary and clean up.

The script checks for active workers and tests, briefly pauses the idle listener
to prevent assignment of another job during deletion, checks again for workers,
and verifies that no files in the two directories are open. It resumes the listener
on completion or error. It only deletes recognized cache files and database
sidecars, preserving unrecognized entries and symlinks. A lock prevents concurrent
cleanup runs. Compiler caches, dependency caches, toolchains, and workspaces are
outside its deletion scope.

This is an explicit maintenance operation, not a scheduled task or runner hook.
Read the JSON report's actual free-space change; filesystem sharing can make that
differ from the sum of allocated file sizes. Older branches can still run the old
code and recreate files until they incorporate the fixes.

Run `python3 scripts/ci-runner-maintenance/test_cleanup.py` to exercise the cleanup
boundaries. The developer script test suite runs these checks too.
