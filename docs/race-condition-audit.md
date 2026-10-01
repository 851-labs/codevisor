# Race condition audit

Audited on 2026-09-30 at commit `335c97e8`.

This is the pre-fix audit. See [race condition repairs](race-condition-fixes.md) for implementation, regression evidence, and verification limits.

Found **20 actionable race conditions**: **13 reproduced with 14 controlled schedules**, and **7 established by source interleavings but not executed**. This is a broad audit, not proof that no other races exist. Priority below reflects the consequence of the demonstrated interleaving, not measured frequency in production.

Reviewed server session creation, prompt dispatch and reconciliation, restart draining, plugin and MCP lifecycles, native MCP file edits, cloud resume and tunnel ownership, Swift navigation and persistence, screenshot completion, direct connections, and artifact locks. Also inspected surrounding callers and existing synchronization in agent runtime, harness lifecycle, worktree lifecycle, file documents, and screen sharing. Production code was not changed.

“Reproduced” means the production owner ran with controlled dependencies or callbacks. These were targeted probes, not full application tests. The native apps, Thread Sanitizer, and Cloudflare workerd were not run. Swift probes compiled the actual owner with minimal supporting type stubs; the cloud probe used the actual resume owner with an in-memory SQLite adapter. Source-only findings are explicitly marked.

## Findings at a glance

| #   | Priority | Location                  | Observable failure                                   | Evidence                                |
| --- | -------- | ------------------------- | ---------------------------------------------------- | --------------------------------------- |
| 1   | High     | Server prompt queue       | Two prompts execute concurrently in one chat         | Reproduced                              |
| 2   | High     | Session creation          | Same chat creates two agents                         | Reproduced                              |
| 3   | High     | Deferred session opening  | First open creates two agents                        | Reproduced                              |
| 4   | High     | Session configuration     | Concurrent choices overwrite each other              | Reproduced; restore variant source-only |
| 5   | High     | Restart drain             | Cancelled restart closes a live agent                | Reproduced                              |
| 6   | High     | Plugin supervisor         | Stopped plugin starts afterward                      | Reproduced                              |
| 7   | Moderate | Plugin forwarding         | Old request failure kills a replacement plugin       | Source-only                             |
| 8   | High     | TypeScript tunnel host    | Old configuration wins; stopped host rebinds         | Reproduced, two schedules               |
| 9   | High     | Swift tunnel endpoint     | Old configuration resumes after reconfigure/shutdown | Source-only                             |
| 10  | Moderate | Cloud resume sessions     | One resume token is accepted twice                   | Reproduced                              |
| 11  | High     | MCP upstream lifecycle    | Old handshake replaces new connection                | Reproduced                              |
| 12  | High     | Native MCP configuration  | Concurrent edits lose changes                        | Reproduced                              |
| 13  | High     | macOS screenshot bridge   | Timeout permits unsynchronized reads/writes          | Source-only                             |
| 14  | Moderate | Remote directory browser  | Old navigation response replaces newer path          | Reproduced; cache variant source-only   |
| 15  | Moderate | Pane group persistence    | Concurrent saves lose a session entry                | Reproduced                              |
| 16  | Moderate | Cloud direct path         | Old disconnect removes a replacement connection      | Source-only                             |
| 17  | High     | Navigation store          | Invalidated snapshots return; newer deltas disappear | Source-only                             |
| 18  | High     | Artifact build lock       | Stale cleanup removes a new live lock                | Reproduced                              |
| 19  | Moderate | Device layout persistence | Older snapshot is persisted after a newer one        | Source-only                             |
| 20  | High     | Stale turn reconciliation | Cleanup can terminate a newly live turn              | Source-only                             |

## 1. Prompt drain claims ownership after yielding

Locations: [prompt-queue.ts:319](../apps/server/src/routes/prompt-queue.ts#L319), [prompt-queue.ts:341](../apps/server/src/routes/prompt-queue.ts#L341), [prompt-turn.ts:27](../apps/server/src/routes/prompt-turn.ts#L27).

Two drains pass `activePromptSessions.has(sessionId)`, then both await `sessionUpdateGate`. Neither rechecks ownership before `beginPromptTurn` adds the session to the set. Even an already-resolved gate yields. Both drains can dispatch prompts; a release also removes the shared set entry without distinguishing which drain owns it.

**Observed:** two simultaneous prompts for one session. This can mix turn completion and lifecycle accounting as well as prompt execution.

**Repair:** acquire a per-session drain claim before the first await, revalidate relevant gates under that claim, and release only the matching owner.

## 2. Session creation deduplication starts too late

Location: [session-workspace.ts:121](../apps/server/src/routes/session-workspace.ts#L121).

`pendingSessionCreates` is checked before awaiting project lookup, but populated only after lookup and after starting the creation operation. Two requests for the same canonical session ID can both pass the check and create agents. The later database update cannot undo the extra process. Unconditional map deletion can also remove another attempt's entry.

**Observed:** two agent spawns for the same chat, with both requests reporting that they created it.

**Repair:** register the entire creation promise synchronously before lookup yields; remove it only if it is still the same promise.

## 3. Concurrent first-open creates two deferred agents

Locations: [session-workspace.ts:270](../apps/server/src/routes/session-workspace.ts#L270), [session-workspace.ts:308](../apps/server/src/routes/session-workspace.ts#L308).

`ensureAgentSessionFor` reads a deferred session with an empty `agentSessionId`, then awaits archive/project/auth/MCP work. Two callers retain that empty snapshot and independently create agents before replacing the database row. Agent-runtime deduplication for an existing provider session ID does not cover two newly allocated IDs.

**Observed:** two spawned agents for one deferred chat. Opening and prompting provide real callers for this path.

**Repair:** serialize initialization per chat, reread the row inside that ownership boundary, and share the result among callers.

## 4. Session picker updates lose changes; restore can overwrite newer choices

Locations: [session-config.ts:98](../apps/server/src/routes/session-config.ts#L98), [session-workspace.ts:399](../apps/server/src/routes/session-workspace.ts#L399), [session-workspace.ts:455](../apps/server/src/routes/session-workspace.ts#L455).

`persistPick` reads the complete saved selection map and later replaces it. Two updates to different pickers can read the same base, then each replace the entire map. Configuration restore similarly keeps a saved snapshot across awaited runtime option changes and can write that old snapshot back after a new choice has been saved. An older restore can also apply a runtime option after a newer picker action.

**Observed:** saving model and speed concurrently left one saved pick instead of two. The overlapping restore variant was established from source, not executed.

**Repair:** use atomic per-key database updates or revision-based merging, and coordinate runtime restore with live picker changes.

## 5. Restart cancellation does not cancel finalization side effects

Locations: [restart-drain.ts:207](../apps/server/src/restart-drain.ts#L207), [restart-drain.ts:233](../apps/server/src/restart-drain.ts#L233), [restart-drain.ts:265](../apps/server/src/restart-drain.ts#L265).

Finalization awaits the resume-session list, writes a restart snapshot, and closes loaded sessions. Cancellation increments the generation, clears the snapshot, and reopens the gate. The generation check is after finalization, so a suspended finalizer can resume after cancellation, recreate the snapshot, and close an agent now serving live work. A subsequent `begin` can also join the still-present cancelled `inFlight` operation.

**Observed:** one agent closed after cancellation, and the cleared snapshot was recreated.

**Repair:** make finalization generation-aware before each side effect and coordinate cancellation with destructive work before reopening dispatch. Keep each operation's cleanup bound to its own identity.

## 6. Plugin startup outlives stop, disable, or removal

Locations: [plugin-supervisor.ts:343](../packages/plugins/src/plugin-supervisor.ts#L343), [plugin-supervisor.ts:396](../packages/plugins/src/plugin-supervisor.ts#L396), [plugin-supervisor.ts:412](../packages/plugins/src/plugin-supervisor.ts#L412).

Startup awaits port allocation and environment resolution before spawning. `stop` kills only the process that exists at that moment; it does not invalidate the suspended startup. A stopped plugin can therefore spawn later. Readiness completion also publishes `running` without checking that it still owns the startup. Manager disable/remove/close operations reach this path, and restart can join an obsolete retained startup promise.

**Observed:** stop during environment resolution was followed by one spawn and a `running` state.

**Repair:** invalidate startup with an operation token, check it after every await and before publishing readiness, and terminate any late process belonging to an invalidated attempt.

## 7. A stale plugin request can kill the replacement process

Locations: [plugins-manager.ts:340](../packages/plugins/src/plugins-manager.ts#L340), [plugins-manager.ts:363](../packages/plugins/src/plugins-manager.ts#L363), [plugin-supervisor.ts:473](../packages/plugins/src/plugin-supervisor.ts#L473). Icon and tool forwarding use equivalent callbacks.

A request captures the old plugin port and awaits forwarding. The plugin restarts and becomes healthy on another port. Failure from the old request calls `markUnreachable(plugin.id)`, which acts on the current process under that ID and can kill the replacement. Stale success can likewise alter the new process's failure accounting.

**Evidence:** source interleaving; not executed.

**Repair:** carry the process/port generation through each forwarded request and accept completion callbacks only for that generation.

## 8. TypeScript tunnel configuration claims a generation after yielding

Locations: [tunnel-host.ts:154](../packages/cloud-client/src/tunnel-host.ts#L154), [tunnel-host.ts:179](../packages/cloud-client/src/tunnel-host.ts#L179).

`configure` awaits `stop()` before capturing the generation. Two configure calls can both complete their synchronous stop work before either continuation runs, then capture the same generation. If the newer bind finishes first, the older bind can overwrite it and leave its endpoint open. Calling stop before a configure continuation resumes also allows configure to capture the stopped generation and bind afterward.

**Observed:** the older configuration became the final owner while the superseded endpoint remained open; a separate schedule left the host running after stop. Existing stop-during-bind coverage starts later than these windows.

**Repair:** claim a unique configuration generation before the first await, preserve its identity through teardown and bind, and close every superseded result.

## 9. Swift tunnel actor reentrancy permits stale binding

Locations: [CloudTunnelEndpoint.swift:111](../packages/swift/CodevisorCloud/Sources/CodevisorCloud/CloudTunnelEndpoint.swift#L111), [CloudTunnelEndpoint.swift:127](../packages/swift/CodevisorCloud/Sources/CodevisorCloud/CloudTunnelEndpoint.swift#L127), [CloudTunnelEndpoint.swift:165](../packages/swift/CodevisorCloud/Sources/CodevisorCloud/CloudTunnelEndpoint.swift#L165), [CloudTunnelEndpoint.swift:173](../packages/swift/CodevisorCloud/Sources/CodevisorCloud/CloudTunnelEndpoint.swift#L173).

Configure updates `config` and then awaits closing the old endpoint. Actor reentrancy lets another configure or shutdown change ownership during that await. The older call resumes and installs a binding without checking its configuration/generation. Awaited previous binding completion and handle close create additional reentry points. This can replace a newer binding or bind after shutdown.

**Evidence:** source interleaving; not executed in the native app.

**Repair:** capture an operation generation before teardown, verify it after suspension, and close late handles that no longer belong to the current configuration.

## 10. A cloud resume token can be claimed twice

Location: [resume-sessions.ts:91](../apps/cloud/src/resume-sessions.ts#L91).

Two resume operations look up the same old token before `register` finishes computing the replacement token's digest and updating storage. Both can adopt the same connection ID. A Durable Object's single JavaScript thread does not serialize an operation across these awaits. Competing welcomes and token rotations can supersede connections and leave one client with a stale replacement token.

**Observed:** two successful claims for one token using the actual resume implementation and a gated WebCrypto digest.

**Repair:** atomically consume/rotate the stored old token with a conditional update, ensuring only one operation can adopt it.

## 11. A stale MCP handshake replaces a newly configured upstream

Locations: [mcp-manager-core.ts:352](../packages/mcp/src/mcp-manager-core.ts#L352), [mcp-upstream.ts:100](../packages/mcp/src/mcp-upstream.ts#L100), [mcp-upstream.ts:106](../packages/mcp/src/mcp-upstream.ts#L106), [mcp-upstream.ts:119](../packages/mcp/src/mcp-upstream.ts#L119), [mcp-upstream.ts:145](../packages/mcp/src/mcp-upstream.ts#L145).

Closing a connection deletes the lock entry but does not invalidate an in-flight handshake. Updating the definition can therefore start a second handshake. The old handshake's final check verifies enabled/suppressed state, but not definition or operation identity, then installs its old client over the new one. Its unconditional `finally` deletion can also remove a newer lock.

**Observed:** real MCP HTTP handshakes against controlled old/new endpoints left the saved definition pointing to the new endpoint while the live tool inventory came from the old endpoint. The probe mirrored the manager's lock invalidation during replacement.

**Repair:** invalidate pending handshakes on close/update, verify definition and generation before installation, close stale clients, and delete only the matching lock.

## 12. Native MCP file edits overwrite each other

Locations: [native-mcp-edits.ts:103](../packages/mcp/src/native-mcp-edits.ts#L103), [native-mcp-edits.ts:140](../packages/mcp/src/native-mcp-edits.ts#L140), [native-mcp-edits.ts:188](../packages/mcp/src/native-mcp-edits.ts#L188), [native-mcp-edits.ts:214](../packages/mcp/src/native-mcp-edits.ts#L214).

Remove, restore, and enable/disable operations independently read a config file, alter that snapshot, and replace the file. Atomic publication does not serialize read-modify-write. Concurrent removals of two different servers can resurrect one server; edits made by the harness between read and replacement can also be discarded. Backup initialization has a separate check-then-write window at `ensureBackup` and uses a shared backup path.

**Observed:** two concurrent removals left one server, when both should have been removed, using the actual editor with a gated filesystem dependency.

**Repair:** serialize by canonical file path and revalidate the file before committing. Detect external edits and merge or retry rather than blindly replacing them. Coordinate backup initialization under the same ownership boundary.

## 13. Screenshot timeout exposes a native data race

Locations: [ComputerUseBridge+Screenshot.swift:95](../packages/swift/CodevisorCoreMac/Sources/CodevisorCoreMac/Server/ComputerUseBridge+Screenshot.swift#L95), [ComputerUseBridge+Screenshot.swift:128](../packages/swift/CodevisorCoreMac/Sources/CodevisorCoreMac/Server/ComputerUseBridge+Screenshot.swift#L128), [ComputerUseBridge+Screenshot.swift:133](../packages/swift/CodevisorCoreMac/Sources/CodevisorCoreMac/Server/ComputerUseBridge+Screenshot.swift#L133).

The screenshot task/callback writes plain mutable fields in an `@unchecked Sendable` box. Both callers ignore whether semaphore waiting timed out and read those fields anyway. A successful wait orders completion; a timeout does not. A late capture can therefore write while the caller reads capture/failure or performs fallback.

**Evidence:** unsynchronized timeout interleaving in source; no live screenshot or Thread Sanitizer reproduction.

**Repair:** handle timeout explicitly and protect outcome settlement with synchronization, or make capture async with a cancellation-aware, single-settlement result. Late completion must not mutate state being read without a lock.

## 14. Go to Folder allows an older response to win

Locations: [RemoteDirectoryBrowserModel.swift:157](../packages/swift/CodevisorCore/Sources/CodevisorCore/ViewModels/RemoteDirectoryBrowserModel.swift#L157), [RemoteDirectoryBrowserModel.swift:276](../packages/swift/CodevisorCore/Sources/CodevisorCore/ViewModels/RemoteDirectoryBrowserModel.swift#L276).

`goToPath` increments navigation generation after awaiting its fetch, rather than claiming/checking a generation before the request. An older slow request can replace the path from a newer successful request, or show an obsolete error. Separately, fetch populates the cache unconditionally, so a listing invalidated during an outstanding request can be repopulated with stale content.

**Observed:** navigating to `/older`, then `/newer`, and completing the older request last left the visible path at `/older`. The cache invalidation variant is source-only.

**Repair:** allocate/check a generation around both success and failure; track cache invalidation epochs per path before accepting a fetched listing.

## 15. Pane repository locks do not cover a save transaction

Locations: [PaneGroupRepository.swift:41](../packages/swift/CodevisorCore/Sources/CodevisorCore/Persistence/PaneGroupRepository.swift#L41), [PaneGroupRepository.swift:67](../packages/swift/CodevisorCore/Sources/CodevisorCore/Persistence/PaneGroupRepository.swift#L67).

Save obtains the dictionary through `loadAll`, changes its local copy outside the lock, then replaces the cache and writes storage separately. Two concurrent saves can start from the same dictionary and each persist only its own addition. Initial loading also permits two stale loaded values to escape independently. `removeAll` can interleave with a save and allow deleted entries to return. The repository is shared by production app wiring and exposes a Sendable contract.

**Observed:** concurrent saves for two session IDs produced one persisted entry using the actual Swift repository.

**Repair:** serialize the complete read-modify-commit operation, including ordered persistence, rather than locking only individual cache accesses.

## 16. An old direct-connection disconnect removes a new connection

Locations: [CloudDirectPathController.swift:141](../packages/swift/CodevisorCloud/Sources/CodevisorCloud/CloudDirectPathController.swift#L141), [CloudDirectPathController.swift:188](../packages/swift/CodevisorCloud/Sources/CodevisorCloud/CloudDirectPathController.swift#L188).

The connection's `onDown` callback schedules a MainActor task carrying only device ID. If the old callback is already queued, the old connection can be dropped and a replacement installed before that task executes. `handleDown` then removes the current connection by device ID. Clearing callbacks during shutdown cannot retract an already scheduled task, and the removed replacement is not shut down there.

**Evidence:** source interleaving; not executed.

**Repair:** include connection identity/generation in the callback and remove or shut down only that matching connection.

## 17. Navigation mapping commits after invalidation and can discard newer deltas

Locations: [NavigationStore.swift:87](../packages/swift/CodevisorCore/Sources/CodevisorCore/Sync/NavigationStore.swift#L87), [NavigationStore.swift:114](../packages/swift/CodevisorCore/Sources/CodevisorCore/Sync/NavigationStore.swift#L114), [NavigationStore.swift:127](../packages/swift/CodevisorCore/Sources/CodevisorCore/Sync/NavigationStore.swift#L127), [MachineController+NavigationSync.swift:293](../packages/swift/CodevisorCore/Sources/CodevisorCore/Server/MachineController+NavigationSync.swift#L293).

`replace` awaits detached snapshot mapping and then commits without an invalidation generation or cancellation check. Forgetting a machine during mapping can be undone by that late result. A cancelled old stream reset can also overwrite newer state because `resetsStream` bypasses the cursor guard. Caller checks before and after awaiting `replace` cannot prevent the commit inside it.

`apply` has a related lost-update window: it maps a delta from cursor 10, a refresh commits cursor 20 while mapping, and the delta for cursor 30 is discarded because the current cursor changed. The function returns success even though cursor 20 does not contain delta 30; the stream can then advance past the discarded event.

**Evidence:** source interleavings; not executed.

**Repair:** give each machine an invalidation/stream generation and verify it before commits. For a delta, compare the latest cursor with the delta's cursor and rebase/retry when the latest state does not yet include it.

## 18. Stale artifact lock removal can unlink a new live owner

Locations: [artifact-lock.mjs:37](../scripts/artifact-lock.mjs#L37), [artifact-lock.mjs:57](../scripts/artifact-lock.mjs#L57). Used by the net and Chromium artifact scripts.

A waiter reads a dead owner's PID, checks liveness, and unconditionally removes the lock path. Another waiter can already have removed that old lock and acquired a new live lock at the same path. The first waiter removes the replacement using its stale observation, admitting concurrent artifact builders. Final cleanup also unconditionally removes the path. A crash between exclusive creation and PID writing can leave an empty lock that does not recover.

**Observed:** the actual lock function entered its protected body after stale cleanup removed a replacement owner. The probe used a real temporary file and the existing liveness-check seam to install the replacement; it did not launch competing live builders.

**Repair:** use a lock protocol/library with ownership-safe stale takeover and release, and defined recovery for partially initialized locks. A plain reread followed by unlink still leaves a check/unlink gap.

## 19. Device layout persistence can enqueue snapshots out of order

Locations: [DeviceLayoutStore.swift:118](../packages/swift/CodevisorCore/Sources/CodevisorCore/Sync/DeviceLayoutStore.swift#L118), [DeviceLayoutStore.swift:184](../packages/swift/CodevisorCore/Sources/CodevisorCore/Sync/DeviceLayoutStore.swift#L184).

Mutation is locked, but persistence captures a snapshot under the lock and enqueues it after unlocking. Thread A can capture an older layout and pause; thread B mutates and enqueues a newer layout; A then enqueues its older snapshot last. The persistence queue's “latest” value becomes stale even though memory is current. The same pattern affects draft promotion/removal, pruning, and clearing. The class advertises cross-thread access through `@unchecked Sendable`.

**Evidence:** source interleaving; not executed. Requires overlapping calls, rather than sequential calls on one executor.

**Repair:** assign revisions under the mutation lock and reject older snapshots at enqueue, or order snapshot capture and enqueue atomically with mutation.

## 20. Stale-turn reconciliation can terminate a newly active turn

Locations: [prompt-queue.ts:176](../apps/server/src/routes/prompt-queue.ts#L176), [prompt-queue.ts:195](../apps/server/src/routes/prompt-queue.ts#L195), [prompt-queue.ts:202](../apps/server/src/routes/prompt-queue.ts#L202).

The healer selects quiet sessions, checks `hasLiveTurn` once, then awaits transcript lookup. A new prompted or autonomous turn can start during that await. The returned generating assistant item can now belong to the new turn, which the healer treats as orphaned, cancels its pending question, and ends through the normal event pipeline. No ownership or original quiet-cutoff check protects those writes.

**Evidence:** source interleaving; not executed.

**Repair:** coordinate reconciliation with per-session turn ownership and perform revision/turn-ID/quiet-cutoff validation when committing each repair. Rechecking only once before another await is insufficient.

## Reproduction artifacts

Probe sources and machine-readable results remain in the ignored workspace directory [tmp/race-audit](../tmp/race-audit/). They introduce no permanent test fixtures or production changes. Probes use explicit barriers/signals and controlled completions rather than timing sleeps.

| Artifact                                                                                                             | Findings   | Recorded result                                                                                                                       |
| -------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| [probe.ts](../tmp/race-audit/probe.ts) / [results](../tmp/race-audit/probe-results.json)                             | 1–6, 8, 12 | Two simultaneous prompts; duplicate agents; lost picker edit; post-cancel close; post-stop spawn; two tunnel schedules; lost MCP edit |
| [cloud-probe.ts](../tmp/race-audit/cloud-probe.ts) / [results](../tmp/race-audit/cloud-results.json)                 | 10         | Two successful claims for one resume token                                                                                            |
| [mcp-probe.ts](../tmp/race-audit/mcp-probe.ts) / [results](../tmp/race-audit/mcp-results.json)                       | 11         | New saved definition, old live tool inventory                                                                                         |
| [artifact-probe.mjs](../tmp/race-audit/artifact-probe.mjs) / [results](../tmp/race-audit/artifact-results.json)      | 18         | Entered while replacement lock owner was live according to the controlled check                                                       |
| [DirectoryProbe.swift](../tmp/race-audit/DirectoryProbe.swift) / [results](../tmp/race-audit/directory-results.json) | 14         | Final path `/older`, expected `/newer`                                                                                                |
| [PaneProbe.swift](../tmp/race-audit/PaneProbe.swift) / [results](../tmp/race-audit/pane-results.json)                | 15         | One saved entry, expected two                                                                                                         |

Run from repository root after installing dependencies:

```sh
bun --tsconfig-override ./tmp/race-audit/tsconfig.json tmp/race-audit/probe.ts
bun tmp/race-audit/cloud-probe.ts
bun --tsconfig-override ./tmp/race-audit/tsconfig.json tmp/race-audit/mcp-probe.ts
node tmp/race-audit/artifact-probe.mjs
swiftc -parse-as-library -swift-version 6 packages/swift/CodevisorCore/Sources/CodevisorCore/ViewModels/RemoteDirectoryBrowserModel.swift tmp/race-audit/DirectoryProbe.swift -o tmp/race-audit/directory-probe
tmp/race-audit/directory-probe
swiftc -parse-as-library -swift-version 6 packages/swift/CodevisorCore/Sources/CodevisorCore/Persistence/PaneGroupRepository.swift tmp/race-audit/PaneProbe.swift -o tmp/race-audit/pane-probe
tmp/race-audit/pane-probe
```

All six probe programs completed successfully and asserted the unexpected behavior. Dependencies were installed with `bun install --frozen-lockfile --ignore-scripts`; the lockfile was unchanged. Local probe execution used Bun 1.3.14. Probe files/results are ignored and will not accompany a commit of this report unless explicitly preserved.

## Suggested repair order

Start with shared per-session ownership for prompt dispatch, session initialization, and reconciliation (1–3, 20), then restart cancellation (5). Those paths can create duplicate agents or interfere with active turns. Next address lost configuration updates (4, 12), stale connection/process ownership (6–11, 16), and screenshot timeout synchronization (13). Follow with navigation/persistence ordering (14, 15, 17, 19) and artifact lock ownership (18), moving the latter earlier if concurrent artifact builds are common.

Each repair should get a behavioral regression that holds the relevant operation at its actual suspension boundary. Sequential happy-path tests do not cover these interleavings.
