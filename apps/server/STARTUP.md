Production macOS starts the bundled server through SMAppService/launchd. Registration or approval failures are reported to the user; there is no app-owned fallback or Safe Mode. The development runner and explicit CLI launches remain supported.

Startup writes `server-startup.json` beside the database before importing the server graph. `--startup-status` can override the file location. Each atomic checkpoint carries a boot ID, PID, process-start timestamp, update timestamp, elapsed milliseconds, stage, and optional counted work. Stage transitions and failures also go to the server log.

The app shows completed milestones, not estimated elapsed-time percentages:

| Completed | Next work                                                   |
| --------- | ----------------------------------------------------------- |
| 0 / 7     | Prepare/register the background service                     |
| 1 / 7     | Start the process                                           |
| 2 / 7     | Import the runtime                                          |
| 3 / 7     | Acquire database ownership, open and migrate data           |
| 4 / 7     | Restore saved terminal buffers                              |
| 5 / 7     | Initialize services                                         |
| 6 / 7     | Start HTTP and verify health                                |
| 7 / 7     | App verified the responding server's boot and bundled build |

Database upgrades and terminal restoration supply their own completed/total counts. Only fresh checkpoints from the current attempt can extend startup; repeated timestamps and backward progress do not count. Keep the stage mappings in `startup-progress.ts` and Swift's `LocalServerStartupProgress` aligned when adding stages.

Local health requests have a two-second deadline. Thirty seconds without forward progress fails the attempt, and ten minutes is the absolute startup limit. A live launchd PID alone does not extend either deadline. A stalled or exited managed process gets one automatic retry after verified shutdown. Registration/approval errors and explicit server startup failures remain actionable failures. The five most recent `startup-failure-*.json` records are retained beside `server.log`.

ServiceManagement calls have a fifteen-second deadline and cannot overlap an outstanding call, including one that timed out but has not returned. Update preparation cancels an in-flight startup. Live-chat draining waits up to fifteen minutes, requests interruption once, then allows fifteen final seconds. Shutdown verifies the previous process, listener, and database lease have been released before allowing replacement. Forced signalling requires a matching database owner record and Codevisor process identity.

The LaunchAgent uses a fixed PATH and starts Node without evaluating user shell startup files. The server resolves the user's shell environment asynchronously with its existing timeout. Sharp loads only when an icon needs normalization. Full foreign-key validation runs after schema migrations, and identity adoption records its completed server ID transactionally so unchanged boots skip those scans.

Use `bun run dev:macos --no-containers` to inspect checkpoint logs in the isolated development environment. Focused regressions live in `startup-progress.test.ts`, `terminal-persistence.test.ts`, database upgrade tests, and Swift's local-server/ownership tests. Native builds use `bun run build:macos` and `bun run build:ios`.
