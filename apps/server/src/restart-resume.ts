import { drainPromptQueue } from "./routes/prompt-queue.js"
import { ensureAgentSessionFor } from "./routes/session-workspace.js"
import {
  RESTART_GATE_HARNESS_ID,
  RESTART_GATE_HARNESS_NAME,
  type RestartSnapshotStore
} from "./restart-drain.js"
import {
  appendAndPublish,
  failureMessage,
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "./server-context.js"

/// Sessions resumed at once after a restart. Deliberately small: the
/// startup comment in server.ts explains why cold-starting every chat at
/// boot starved /health; this only touches the sessions the drain snapshot
/// named, a few at a time, after the listener is already up.
const RESUME_CONCURRENCY = 2

/// The boot half of the restart drain: reconnects the sessions the previous
/// process snapshotted (those with a live agent process or a held prompt at
/// shutdown) through each harness's native resume, then drains any prompts
/// that were held behind the gate. The snapshot is consumed first so a
/// crash mid-resume never loops.
export const resumeSessionsAfterRestart = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  snapshot: RestartSnapshotStore,
  log: (line: string) => void = (line) => console.log(line)
): Promise<ReadonlyArray<string>> => {
  const requested = snapshot.read()
  snapshot.clear()
  if (requested === undefined || requested.length === 0) return []
  const sessions = await run(services.db.listSessions)
  const known = new Map(sessions.map((session) => [session.id, session]))
  // The previous process published `waiting` for every session it held and
  // then exited — its `released` never happened. Publish it here, durably,
  // so clients replaying the stream (or still showing the marker) let go
  // before the held prompts dispatch.
  for (const sessionId of requested.filter((id) => known.has(id))) {
    await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
      harnessId: RESTART_GATE_HARNESS_ID,
      harnessName: RESTART_GATE_HARNESS_NAME,
      state: "released"
    }).catch(swallowError)
  }
  const targets = requested.filter((id) => known.get(id)?.isArchived === false)
  if (targets.length === 0) return []
  log(`Resuming ${targets.length} session(s) after the restart`)
  const resumed: Array<string> = []
  const queue = [...targets]
  const worker = async (): Promise<void> => {
    for (let next = queue.shift(); next !== undefined; next = queue.shift()) {
      const sessionId = next
      try {
        await ensureAgentSessionFor(services, fanout, serverId, sessionId)
        resumed.push(sessionId)
      } catch (cause) {
        // The session reconnects lazily on its next /connect, as before.
        log(`Could not resume session ${sessionId}: ${failureMessage(cause)}`)
      }
      const pending = await run(services.db.listPromptQueue(sessionId))
      if (pending.length > 0) {
        void drainPromptQueue(services, fanout, routeState, serverId, sessionId).catch(swallowError)
      }
    }
  }
  await Promise.all(Array.from({ length: RESUME_CONCURRENCY }, () => worker()))
  return resumed
}
