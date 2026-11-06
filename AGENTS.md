# Codevisor agent rules

## Killing processes

Many agents, dev runners, simulators, and apps share each machine, including the Codevisor app that runs your own chat. A kill that matches by pattern takes all of them down with it.

- Kill only processes you started. Keep the PID (`$!`, the spawn result, or the runner's PID file) and `kill <pid>`, or stop the background task you started. For a tree you started in its own process group, use `kill -- -<pgid>`.
- Never kill by pattern or name: no `pkill`, `killall`, `kill $(pgrep …)`, `pgrep … | xargs kill`, or `lsof -t … | xargs kill`. On macOS, `pkill` stops reading options at the first pattern, so `pkill -f "x" -U 501 -n` also matches `-U`, `501`, and `-n`, and `-n` matches `--no-chrome` in every Claude process.
- To stop a process you didn't track, list it first with `pgrep -fl <pattern>` (every option before the pattern) or `ps -o pid,ppid,command -p <pid>`. Check each line, then `kill` only the PIDs that are yours.
- Never stop another worktree's or chat's processes, the installed Codevisor app, or a harness CLI (`claude`, `codex`, `opencode`, and so on) you didn't start. If one is in your way, report it.
- Repo scripts follow the same rule: track the PIDs or process groups they start, or confirm a candidate's exact executable or working directory before killing it.

`scripts/agent-hooks/kill-guard.mjs` runs before every shell command in each harness that loads this repo's hooks and blocks the pattern forms above.

## Landing changes

`main` only moves through the merge queue; direct pushes are rejected.

- Commit on a branch, then run `bun run ship`. It rebases onto `origin/main`, pushes (the pre-push hook runs the checks your changes affect, except Swift tests), opens or reuses the PR, and queues it with auto-merge. Pass `--title`/`--body` for the PR text, `--wait` to block until it lands, or `--review` to open it without queueing.
- The merge queue runs CI on `main` plus everything queued ahead, including Swift tests on a Mac when Swift changed. If your PR leaves the queue, read its checks, fix the branch, and ship again.
- Pre-commit only checks formatting and lint on staged files. Run `bun run check` while you work for feedback on everything you changed.
- Never bypass the queue (`gh pr merge --admin`, force-pushing `main`) unless the user asks you to.
