# Persistent session host

Linear: 851-2771. Status: the interrupt-and-continue part of option A is built (v1). Updates no longer
wait for chats: running turns are interrupted and recorded in `paused-for-update.json`, end with stop
kind `interrupted`, and get a hidden "continue" a few seconds apart after the restart. The rest is
design only.

## Summary

Today every app update restarts the local server, and a server restart ends everything agents are doing.
Harness CLIs, terminals, the dev servers and background tasks they started, pending permission prompts
and in-flight tool calls all go. Chats come back by starting a new harness process with the harness's
own resume ID. The turn that was running is closed as if it had finished.

The proposal is to move the things that must outlive a restart into a **session host**: a separate,
long-lived process that owns the harness processes and PTYs. It journals their output and lets a
restarted server reattach and replay from where it left off. The design borrows three ideas:

- **The process model from containerd-shim and herdr.** Children belong to a process that is not the
  one being upgraded.
- **The byte-level journal and ack/replay from VS Code's `PersistentProtocol` and zed's `ChannelClient`.**
- **A generation model for upgrading the host itself.** Rather than ever restarting a busy host, a new
  host takes new sessions and the old one retires when its sessions go idle. This replaces fd handoff.

Recommended first step: the **UI-only fast path**, plus running the server from a digest-addressed copy
outside the app bundle. It is small and safe, and the host needs that relocation anyway. After that,
build the host in phases: terminals first, then agents.

## 1. Today: process tree and lifecycle

### Who launches what

```
launchd (gui/<uid>)
 ├─ Codevisor.app                     Sparkle, Chromium helpers, app-instance flock
 │    └─ (dev only) node main.js serve --app-owned 1 --owner-pid <app>
 └─ com.851labs.Codevisor.ServerAgent  LaunchAgent, KeepAlive, no AbandonProcessGroup
      └─ codevisor-server-agent (bash) → exec node "codevisor-server" serve …
           ├─ claude CLI                 spawned by claude-agent-sdk query(), same process group
           ├─ codex app-server           detached (own session), stdio JSON-RPC
           ├─ ACP harnesses              cursor, grok, opencode acp, generic ACP; detached, stdio
           ├─ pi / muse / agy            detached, stdio
           │    └─ agent-started work    Bash run_in_background, dev servers, MCP stdio servers
           ├─ node-pty shells            own session per PTY
           │    └─ anything the user or agent runs in a terminal
           ├─ opencode serve             setup/auth only, not detached
           ├─ plugin processes           detached, supervised with backoff
           ├─ upstream stdio MCP servers
           ├─ managed Chromium           reattached on restart via connectExistingProfile
           └─ caffeinate -w <server pid>
```

Key facts:

- **The server is not a child of the app in production.** It is a launchd LaunchAgent registered with
  `SMAppService` (`apps/macos/Codevisor/LaunchAgents/com.851labs.Codevisor.ServerAgent.plist`,
  `apps/macos/Codevisor/Features/Updates/MacServerAgentController.swift`). Quitting the app leaves it
  running. In dev the app spawns it and the server polls the owner PID (`apps/server/src/serve-boot.ts:181`).
- **Every harness runs as one child process per loaded chat**, speaking stdio. The Claude adapter runs the
  SDK in the server and the SDK spawns the CLI (`packages/adapter-claude/src/start-session.ts:121`). Codex
  runs `codex app-server` over stdio (`packages/adapter-codex/src/client.ts:41`). ACP harnesses go
  through `packages/adapter-acp/src/stdio-connector.ts:70`. No harness runs in-process.
- **Terminals are node-pty in the server** (`packages/terminal/src/node-pty-spawner.ts:15`). The Swift
  side only renders. The server keeps a 2 MB `ReplayBuffer` and a ghostty-vt screen model per terminal,
  and clients already reattach with `lastOutputSeq` (`packages/terminal/src/terminal-manager.ts:205`).
- **The `codevisor` MCP gateway runs in the server**, as streamable HTTP at
  `127.0.0.1:49361/mcp/gateway?gateway=<id>` (`apps/server/src/server-router.ts:117`). The bearer token
  is stable across restarts, but the gateway ID is random and kept only in memory
  (`packages/mcp/src/mcp-manager-gateway.ts:78`). `execute` runs in an in-process QuickJS sandbox.
- **Codevisor has no dev-server manager.** Dev servers are either `run_in_background` children of the
  harness CLI or processes in a Codevisor terminal. Either way their lifetime is tied to a process the
  server owns.

### How an update is applied

The app bundle contains the server runtime (`scripts/release/build-macos-app.sh:66`), and the two are
versioned as one. Linux and remote servers update themselves from tarballs (`apps/server/src/serve-self-updater.ts`).

The macOS update sequence (`apps/macos/Codevisor/Features/Updates/SparkleUpdateController.swift:220`):

1. Sparkle finds an update and postpones the relaunch.
2. `prepareForAppUpdate` drains the server (`POST /v1/restart/drain`, `apps/server/src/restart-drain.ts`).
   It gates new prompts and waits for running turns: up to 10 minutes on the server side and 15 on the
   app side. Then it interrupts once and allows 15 more seconds.
3. The drain writes `restart-resume.json` and calls `closeAgentSession` on every loaded session.
4. `/v1/shutdown`, the `SMAppService` job is unregistered, and the app waits for the PID, lockfile and
   port to be released.
5. Sparkle swaps the bundle and relaunches.
6. The new app finds a version mismatch. The check requires version, build number **and git SHA** to
   match (`LocalCodevisorServer+Health.swift:22`). It re-registers the agent, and `ensureRegistered`
   always unregisters an enabled job first (`MacServerAgentController.swift:99`).
7. The new server boots:
   - `reconcileOrphanedSessionTurns` closes interrupted turns as `end_turn`, cancels pending questions
     and clears background tasks (`apps/server/src/routes/prompt-recovery.ts:25`).
   - `resumeSessionsAfterRestart` starts fresh harness processes with resume IDs
     (`apps/server/src/restart-resume.ts`).

**Every app update restarts the server, even when the server bytes did not change.** Remote servers
take the same path through `POST /v1/update/apply`, then `systemctl restart` or a detached re-exec.

### What dies on an update, and why

| Thing                                        | Dies?                                  | Why                                                                                                                                                                    |
| -------------------------------------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Running turn                                 | Waited for (≤15 min), then interrupted | The drain closes every agent session before shutdown                                                                                                                   |
| Harness CLI process                          | Yes                                    | `closeAgentSession` stops the tree. If the server just dies, the stdio client is gone: Codex stdio mode exits on EOF, and the Claude SDK SIGTERMs its children on exit |
| Agent background tasks and dev servers       | Yes                                    | They are children of the harness CLI, whose process tree is stopped                                                                                                    |
| Pending permission or question prompt        | Yes, marked cancelled                  | The live promise is in adapter memory; boot reconcile emits `question_resolved: cancelled`                                                                             |
| Terminal shells and what runs in them        | Yes                                    | The PTY master closes with the server and the kernel sends SIGHUP. Only the scrollback comes back, as a dead read-only terminal (`terminal-manager.ts:329`)            |
| In-flight `codevisor` MCP tool call          | Yes                                    | The work runs inside the server. After restart the old gateway URL returns 404 because its ID was random                                                               |
| MCP background jobs                          | Yes                                    | Held in memory; the job output directory is wiped at startup                                                                                                           |
| Plugins, upstream MCP, caffeinate            | Restarted                              | Owned by the server; they are cheap to restart                                                                                                                         |
| Queued prompts                               | Survive                                | `prompt_queue_items` lives in SQLite                                                                                                                                   |
| Transcript, including partial streaming text | Survives                               | Every runtime event is written to SQLite before it is published                                                                                                        |

Two pre-existing problems turned up along the way:

- **Detached harness trees can leak.** If the server is SIGKILLed, the process-tree tracker dies with it,
  and nothing at boot kills the orphans.
- **Under systemd the default `KillMode=control-group` kills every child**, detached or not. A host on
  Linux must run outside the server's cgroup.

## 2. Where session state lives

| State                                             | Where                                                                                                                                                                                                        | Lost on server restart even if the child survived?                                                                                               |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Transcript, chat items, partial text              | SQLite `events`, `session_events`, `chat_items`, `transcript_*`                                                                                                                                              | No                                                                                                                                               |
| Prompt queue                                      | SQLite `prompt_queue_items`                                                                                                                                                                                  | No, except items being claimed                                                                                                                   |
| Resume ID (Claude session, Codex thread, …)       | SQLite `sessions.agent_session_id`, plus the harness's own JSONL/rollout                                                                                                                                     | No                                                                                                                                               |
| Client sync cursors                               | `events.id` and `session_events.revision`; clients replay with `?since=`                                                                                                                                     | No                                                                                                                                               |
| `ManagedSession` map and per-session emit chain   | `agent-runtime-core.ts:28`                                                                                                                                                                                   | Yes                                                                                                                                              |
| Adapter protocol state                            | Claude: SDK `Query`, `InputQueue`, `turnActive`, tool-input accumulators, `deferredPrompts`. Codex: `threadId`, `activeTurnId`, JSON-RPC `nextId`/`pending`. ACP: SDK connection and outstanding request IDs | Yes. **This is the hard part.** A new server process cannot pick up a stdio JSON-RPC conversation or an SDK `Query` that another process started |
| Pending permission/question promises              | Adapter memory (`pendingQuestions`)                                                                                                                                                                          | Yes. The question text survives in the transcript; the thing that answers it does not                                                            |
| Route state                                       | `activeTurnSessions`, `turnHeldSessions`, `gatedSessions`, … (`apps/server/src/server.ts:68`)                                                                                                                | Yes, but it can be rebuilt from the host                                                                                                         |
| Outbox and steer chains                           | `session-event-outbox.ts:32`, `prompt-queue.ts:226`                                                                                                                                                          | Yes                                                                                                                                              |
| MCP gateway IDs, MCP session IDs, background jobs | `mcp-manager-gateway.ts`, `mcp-gateway-jobs.ts`                                                                                                                                                              | Yes                                                                                                                                              |
| Harness OAuth token refresh, `beforeTurn` hooks   | Callbacks from the adapter into the server (`HarnessAccountContext`)                                                                                                                                         | They need the server reachable when they run                                                                                                     |

Two conclusions follow:

- **Keeping the child alive is not enough.** The process that speaks the harness's protocol has to
  survive too, or every adapter has to learn to resume a stdio conversation mid-stream.
- **The durable side is already in good shape.** The event log is append-only and clients replay from
  an offset, so a server that reattaches only needs to append what it missed.

## 3. Precedent

| System                        | What survives                                                           | Mechanism                                                                                                                                                                                                                                        | Lesson for us                                                                                                           |
| ----------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| containerd-shim               | Containers across containerd restarts and upgrades                      | One small shim per container is the parent and holds stdio. containerd reconnects over a per-shim socket. Old shims keep their old version                                                                                                       | Upgrading the manager is trivial if the process that owns children is not the manager. Version skew is handled per shim |
| tmux / zellij                 | Panes across client detach                                              | A server owns the PTYs and clients are views. Upgrading the server means killing it                                                                                                                                                              | Byte-level ownership is simple; upgrading the owner is the hard part                                                    |
| herdr (agent-focused tmux)    | Panes across **server** upgrade                                         | Passes PTY fds to the new server with `SCM_RIGHTS`, plus a handshake. After a full restart it relaunches agents with `claude --resume` / `codex resume`                                                                                          | fd handoff works for PTYs, but it does not carry protocol state above the bytes                                         |
| VS Code ptyHost               | Terminals across window reload                                          | A separate process owns PTYs. Headless xterm serializes the screen for replay on reattach. 60 s / 6 s grace times. Revive spawns a _new_ shell with old scrollback                                                                               | Our terminal manager already has this shape; it just needs to run in another process                                    |
| VS Code remote / zed remote   | Server state across network drops                                       | Numbered messages, acks, a resend queue for unacked messages, reconnection tokens with a grace period (3 h / 5 min)                                                                                                                              | The replay protocol to copy for host↔server                                                                             |
| launchd daemons               | —                                                                       | `KeepAlive` restarts. A separate job is not killed when another job stops. `AbandonProcessGroup` controls whether children are killed                                                                                                            | The host should be its own job, not a child of the server job                                                           |
| Codex app-server              | Turns across **client** disconnect, but only in unix-socket/daemon mode | `--listen unix://`. A thread stays loaded for 60 s with no subscribers; `thread/resume` reattaches. In stdio mode, EOF shuts all threads down. Only one process may hold a thread open                                                           | Codex could reattach natively, but the transport is marked experimental                                                 |
| Claude Code via the Agent SDK | Nothing                                                                 | stdio stream-json, same process group. The SDK closes stdin, then SIGTERMs after 2 s, then SIGKILLs. It kills children on parent exit. The transcript JSONL is flushed about every 100 ms. `spawnClaudeCodeProcess` lets us supply our own spawn | The SDK `Query` must live in the same process as the CLI's pipes. Resume from JSONL is the fallback                     |
| OpenCode server               | Turns across HTTP disconnect                                            | Turns run in a server scope, not the request. SSE has no replay, so clients refetch state                                                                                                                                                        | —                                                                                                                       |

Sources: codex and opencode from `.repos` (checked out in a sibling worktree), Claude SDK 0.3.211 from
`node_modules`, VS Code, herdr and zed from upstream `main`. The Claude CLI's exact stdin-EOF behavior
is compiled into the binary and was not confirmed.

## 4. Proposed architecture

### 4.1 Shape

```
launchd
 ├─ Codevisor.app
 ├─ ServerAgent job ─ codevisor-server     DB, HTTP/WS API, sync, MCP gateway, plugins, updater
 │                        │ unix socket (versioned host protocol)
 └─ SessionHost job ─ codevisor-host@G     generation G; runs from Runtime/<digest>/
                         ├─ agent sessions: adapter + SDK + harness CLI (+ their children)
                         ├─ PTYs: node-pty + ReplayBuffer + ghostty-vt screen
                         └─ gateway proxy: per-generation 127.0.0.1 port
```

The **host runs the agent runtime itself**: `AgentSessionHandle`, the adapters, and the SDK. It does
not just pipe bytes. That puts the boundary at Codevisor's own interface (`packages/agent-runtime/src/types.ts`):

- **Commands:** `prompt`, `steer`, `cancel`, `setMode`, `setConfigOption`, `setGoal`, `clearGoal`,
  `answerQuestion`, `readContext`, `close`.
- **Events:** the `RuntimeEvent` stream.

The interface is small and already serializable. One boundary covers all ten harnesses. The rejected
alternative is a dumb byte-pipe host, which would require teaching every adapter to resume a
half-finished JSON-RPC or stream-json conversation. That is especially hard for Claude, since the SDK
`Query` cannot attach to a CLI it did not start.

The price of this choice is that the host contains adapter code, which changes often. Section 4.6
handles that with generations: a host is **rarely restarted**, not rarely changed.

### 4.2 What moves and what stays

**Moves into the host:**

- `AgentRuntime` session lifecycle: create, load, prompt, and the other commands, plus the adapters.
- PTY spawning, the replay buffer and the terminal screen model.
- The emit chain that orders events within a session.
- Process-tree tracking for everything above, and orphan cleanup.
- A thin gateway proxy (section 4.9).

**Stays in the server:**

- SQLite and everything derived from it: transcript materialization, the prompt queue, sync and
  navigation.
- The HTTP/WS API and client auth.
- The MCP gateway implementation: QuickJS `execute`, automation, browser, skills.
- Harness discovery, installs and updates, auth probes, usage limits.
- Plugins, cloud tunnel, relay, VNC, updater.

**Becomes host→server RPC:** `HarnessAccountContext.oauth.token` and `beforeTurn`, and `envFor`, which
needs the resolved shell environment. These must tolerate the server being briefly down: retry with a
deadline, then fail the turn with an auth or "server unavailable" error.

### 4.3 IPC and protocol

- **Transport.** A unix domain socket at `~/.codevisor/run/host-<generation>.sock`. Its directory is
  `0700`, and the socket file is `0600`. NDJSON frames, so it is debuggable with `socat`.
- **Handshake.** `hello {protocol: N, minProtocol: M, generation, digest, features[]}`. The server
  refuses a host whose protocol range does not overlap its own. It then falls back to today's
  drain-and-resume for that host's sessions. Rule: **additive changes only within a major version**.
  Unknown event kinds and fields pass through to SQLite untouched. They are already stored as opaque
  `payload`.
- **Frames.**
  - `cmd {id, sessionId, op, args}` / `result {id, ok|error}`
  - `event {sessionId, seq, kind, subjectId, payload}`
  - `ack {sessionId, seq}`
  - `rpc {id, op}` for host→server callbacks
  - `list`, `attach {sessionId, afterSeq}`, `ping`/`pong` with a 5 s interval and 3 misses (same as zed)
- **`prompt` returns when the turn is accepted**, not when it finishes. Turn completion is an event.
  That lets a turn outlive the server's call.

### 4.4 Buffering while the server is down

- The host assigns a per-session `seq` to every `RuntimeEvent`. It appends each event to an in-memory
  ring and spills to `~/.codevisor/run/journal/<sessionId>.ndjson` past a threshold of about 1 MB per
  session.
- An emit resolves as soon as the event is journaled, so adapters never block on the server.
- The server writes `host_seq` into `sessions` **in the same SQLite transaction** as `appendEvent`.
  It acks after the commit, and the host trims up to the acked seq.
- The result is exactly-once delivery into the DB across crashes on either side, the same scheme as VS
  Code's `PersistentProtocol` unacked queue.
- Bound: if a journal exceeds 64 MB (a server down for a very long time, or a runaway stream), the
  host coalesces consecutive text deltas and keeps going. It never drops turn-boundary or question
  events.

### 4.5 Reattach and replay (server boot)

1. Connect to every `host-*.sock`, then `hello` and `list`. Each session reports
   `{generation, turnActive, pendingQuestionId, backgroundTasks, lastSeq}`.
2. For each live session, `attach {afterSeq: sessions.host_seq}`, then replay into the normal
   `sessionEventSink`. Events that arrived while the server was down land in the DB and reach clients
   through the existing `?since=` sync.
3. Rebuild route state (`activeTurnSessions`, held sessions, background tasks) from the `list` reply,
   not from the DB.
4. **Change `reconcileOrphanedSessionTurns` so it skips sessions that a host reports alive.** Today it
   would close their streaming items and cancel their questions. Sessions with no host owner keep
   today's behavior.
5. Drain the prompt queue as usual. Queued prompts become `prompt` commands to the host.
6. If a host is gone, for example after a crash or reboot, fall back to today's resume. Add an
   `interrupted` stop kind so the transcript is honest instead of claiming `end_turn`.

### 4.6 Updating the host: generations, not handoff

A host never restarts while it has live sessions.

- **A new digest starts a new generation.** On boot, a server whose runtime digest differs from the
  newest host's starts host `G+1` from its own runtime copy. New sessions go to `G+1`.
- **Old sessions roll at a safe point.** That is: turn ended, no pending question, no running
  background task, and no attached terminal with a running foreground job. At that point the server
  closes the session in `G` and loads it in `G+1` with the resume ID. This is today's resume path, run
  at a moment when nothing is lost. A chat whose dev server runs for days stays on `G` until it is
  stopped.
- **A host with no sessions and no terminals exits** after a grace period of about 5 minutes.
  Usually one generation is live, and briefly two.
- **Each generation runs from `~/Library/Application Support/Codevisor/Runtime/<digest>/`**, a copy
  made at install time. Sparkle replacing the bundle cannot break lazy imports or native addons in a
  running host. Old runtime copies are garbage-collected once no host uses them.
- **Rejected:** fd handoff with `SCM_RIGHTS`, as herdr does. It moves bytes but not adapter memory.
  Node cannot send arbitrary fds without a native addon. Generations need neither.
- **Emergency fix to a running generation:** the update can mark `G` "must roll". The server then rolls
  each session at its next safe point. It interrupts only if the user agrees in the Update Center.

### 4.7 Crash isolation

- **The server crashing** has no effect on running chats. Events buffer in the host.
- **A host crashing** loses that generation's sessions. That is the same as a server restart today, and
  the server resumes them. To keep that rare, host code is limited to process ownership and adapters.
  No DB, no HTTP and no QuickJS run in the host.
- **One bad adapter can crash the whole host.** If that becomes a problem, the containerd-style
  refinement is one host process per session. It costs about 40–60 MB per Node process, so it should
  not be the default.
- **Launchd job.** The host is its own LaunchAgent, `com.851labs.Codevisor.SessionHost`, so stopping the
  server job never signals it. Use `KeepAlive` only to restart after a crash.
- **Each harness tree gets its own process group**, as today. On start, the host also kills any
  recorded tree whose recorded host is gone, which fixes today's leak.
- **Linux.** Run the host as its own systemd user unit, `codevisor-host@<generation>.service`, so the
  server unit's control-group kill does not reach it.

### 4.8 Security

- **Socket permissions.** The socket lives in a per-user `0700` directory under `~/.codevisor/run`.
  Using `/tmp` would make the path guessable. On accept, the host checks the peer UID with
  `getpeereid` / `SO_PEERCRED` and rejects anyone else.
- **Shared secret.** The server and host also share a token in a `0600` file next to the DB, as the
  computer-use socket already does. This blocks other same-user processes that only hold a path.
- **The host exposes no TCP API.** The gateway proxy listens on `127.0.0.1` with the existing bearer
  token, the same as the gateway today.
- **Journals contain transcript text.** They are written `0600`, trimmed on ack, and deleted when a
  session closes.

### 4.9 The MCP gateway during a restart

The gateway stays in the server: it is large, changes often, and needs the DB. Two changes make
restarts invisible to harnesses:

1. **Stable gateway IDs.** Derive the ID as `HMAC(gatewayKey, sessionId)`, or persist it, instead of
   generating random bytes. Serve the endpoint in stateless streamable-HTTP mode, or accept unknown
   `Mcp-Session-Id`s by transparently re-initializing. After a restart the same URL then keeps working.
2. **A host-side proxy.** Harnesses are configured with the **host's** gateway port, not the server's.
   The proxy forwards to the server:
   - **Server unreachable:** hold new requests for up to 60 s, then return a tool error that says
     Codevisor is restarting and the call can be retried.
   - **Request cut mid-call by the restart:** return the same retryable error. The work ran in the
     server and is gone; the agent sees a failed tool call, not a dead MCP server.
   - **Long `execute` calls** already become background jobs. Move job state into SQLite, or make the
     drain wait for running jobs, so a restart does not silently lose them.

Pi and Antigravity already reach the gateway through a stdio bridge script that reads the URL from an
environment variable. They get the proxy URL the same way.

### 4.10 Terminals and dev servers

PTYs go into the host unchanged. The server's terminal socket route proxies frames to the host. The
existing `lastOutputSeq` replay and `reset` screen frames already handle reattach, so clients notice
nothing.

Dev servers survive either way: those started in a terminal live under the PTY, and those started by
an agent live under the harness CLI. Both are now in the host.

Terminals pin their generation, and that is acceptable. The terminal code is stable, and an idle
generation holding only terminals costs one Node process.

### 4.11 The UI-only fast path

About **31 of the last 100 alpha-to-alpha updates** touched only native or app-side files, with no
server inputs. Only **2 of the last 20 stable-to-stable updates** did, because a stable release spans
many commits. So this path helps alpha users a lot and stable users little. That is why it is a quick
win and not the solution.

1. **Server digest.** At build time, compute a digest of the packaged server runtime, either the bytes
   or the sorted file hashes. Write it to `BUILD.json`, `Info.plist` (`CodevisorServerDigest`) and the
   appcast item, using a custom `codevisor:serverDigest` element that Sparkle exposes through
   `SUAppcastItem.propertiesDictionary`.
2. **Skip the drain and stop when the server will not change.** In `shouldPostponeRelaunchForUpdate`,
   if the item's digest equals the running server's `/health` digest, skip `prepareForAppUpdate`
   entirely.
3. **Adopt on the digest.** `healthMatchesBundledRuntime` compares the digest instead of the git SHA,
   so a new app adopts a byte-identical server. `ensureRegistered` must not unregister an already
   enabled job when the running server matches. Today it always does.
4. **Run the server outside the bundle.** Run it from `Runtime/<digest>/`. The agent script execs that
   copy, and the app populates it on first launch of a new build. Otherwise a lazy import, such as
   Sharp, could hit the bundle while Sparkle is replacing it.

The same digest gives the Update Center and remote updater "server unchanged, app only" for free.
Later it also tells the server whether it needs a new host generation.

## 5. Options

|                                          | What                                                                                                                                                                                                                                                                                            | Survives an update                                                                                                                                    | Effort          | Risk                                                                                                                                                                |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A. Quick wins**                        | UI-only fast path (4.11); server runs from a digest copy; honest `interrupted` stop kind; for server changes, interrupt-and-continue instead of a 15-minute drain (cancel, restart, then resume with a "continue" nudge, as Claude's stream recovery already does); orphan-tree cleanup at boot | Everything on UI-only updates (~⅓ of alpha). Otherwise chats pause for seconds and continue, but terminals, dev servers and pending prompts still die | 1–2 weeks       | Low. The auto-continue nudge can repeat a side effect the agent had already started                                                                                 |
| **B. Terminal host + gateway hardening** | A plus a host process that owns only PTYs (4.10), stable gateway IDs, and the gateway proxy (4.9). Generations apply to the terminal host                                                                                                                                                       | Terminals and anything started in them, including user-started dev servers. Agent turns still restart                                                 | 3–4 weeks more  | Medium. New process and launchd job, socket protocol, terminal latency through one more hop                                                                         |
| **C. Full session host**                 | B plus agents in the host (4.1–4.7): journal and ack, reattach on boot, reconcile changes, host→server RPC for OAuth and env, generations with rollover at safe points                                                                                                                          | Running turns, pending prompts, agent background tasks and dev servers, all across server updates. Only a host crash or reboot interrupts             | 6–10 weeks more | Medium-high. Adapters must not assume they share a process with the server. Every `RuntimeEvent` change must stay backward-compatible. Two generations raise memory |

## 6. Recommended phased plan

1. **Phase 0 (A): fast path and runtime relocation.** Ship the digest, the skip-drain check, adopt-by-digest, a
   non-destructive `ensureRegistered`, the `Runtime/<digest>/` copy, the `interrupted` stop kind and
   orphan cleanup. Measure how often updates are UI-only in practice.
2. **Phase 1: the host skeleton with terminals.** Add the LaunchAgent and systemd unit, the socket with
   peer-UID and token checks, the handshake, the journal and ack, and generations. Move PTYs first.
   They are byte streams with reattach already built, so they prove the plumbing at low risk.
3. **Phase 2: gateway.** Add stable gateway IDs, the stateless or re-initializing endpoint, the host
   proxy, and durable or drained background jobs.
4. **Phase 3: agents.** Move `AgentRuntime` sessions into the host behind a feature flag:
   - one harness first: Codex has the simplest adapter, and Claude is the most used;
   - then the ACP family;
   - then Pi, Muse and Antigravity.

   Also: host→server RPC for OAuth and env, the reconcile changes, and the route-state rebuild. Keep
   today's drain-and-resume as the fallback whenever a session has no compatible host.

5. **Phase 4: rollover.** Roll sessions to the newest generation at safe points, and add Update Center
   copy for the rare forced roll. Then drop the 15-minute drain from the normal update path.

## 7. Verify before building

- **Claude CLI on stdin EOF.** Does it finish the running turn or abort? Through the SDK it is killed
  2 s after stdin closes, so this only matters for a design that bypasses the SDK. Phase 3 does not
  bypass it.
- **Claude Code's HTTP MCP client.** Does it retry, or mark the server failed, after an `ECONNREFUSED`
  or a 404? This decides how much the gateway proxy must hide.
- **Codex `--listen unix://`.** If it becomes supported, Codex could reattach natively without being
  hosted. Also check what happens to server→client approval requests when the connection drops.
- **`SMAppService` behavior for two jobs from one bundle across a Sparkle replacement.** Does
  replacing the bundle restart either job? It should not, but confirm it, because the server job is
  currently unregistered by hand during updates.
- **Memory.** Measure a host carrying about 20 sessions against today's server, plus the
  two-generation peak.
- **The full list of adapter→server dependencies.** Anything beyond `HarnessAccountContext`,
  `ToolGatewayConfig` and `ProviderEnvironment` that an adapter reads from server memory has to become
  RPC or move with it.
