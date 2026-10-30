import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { InterruptedTurnResume } from "@codevisor/agent-runtime"
import { Effect } from "effect"

import { observableFixture, waitFor } from "./changes-test-support.js"
import type { RunningCodevisorServer } from "./server.js"
import type { makeAgents } from "./test-support-agents.js"
import { jsonRequest, run, runningServers, tempDirs } from "./test-support.js"
import { field } from "./unknown-values.js"

export const restartStatePaths = () => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-drain-state-"))
  tempDirs.push(root)
  return {
    restartSnapshotPath: join(root, "restart-resume.json"),
    pausedTurnsPath: join(root, "paused-for-update.json")
  }
}

export const stopServer = async (server: RunningCodevisorServer): Promise<void> => {
  runningServers.splice(runningServers.indexOf(server), 1)
  await run(server.close)
}

export const pauseForUpdate = async (server: RunningCodevisorServer): Promise<void> => {
  await jsonRequest(server, "/v1/restart/drain", { method: "POST" })
  await waitFor(
    async () => field((await jsonRequest(server, "/v1/restart/drain")).body, "state") === "drained"
  )
}

export const withNativeTurnResume = (
  agents: ReturnType<typeof makeAgents>,
  options: { readonly startsTurn: boolean } = { startsTurn: true }
) => {
  const pauses: Array<string> = observableFixture([])
  const resumes: Array<InterruptedTurnResume> = observableFixture([])
  const loadAgentSession = agents.loadAgentSession
  Object.assign(agents, {
    pauseForRestart: (sessionId: string) =>
      Effect.map(agents.cancel(sessionId), () => {
        pauses.push(sessionId)
        agents.sinks.delete(sessionId)
        return { runtimeState: "retire" as const, resumesInterruptedTurn: true }
      }),
    loadAgentSession: (...args: Parameters<typeof loadAgentSession>) =>
      Effect.tap(loadAgentSession(...args), () =>
        Effect.promise(async () => {
          const [, agentSessionId, , , , , sessionOptions] = args
          const resume = sessionOptions?.resumeInterruptedTurn
          if (resume === undefined) return
          resumes.push(resume)
          if (!options.startsTurn) return
          await agents.emit(agentSessionId, {
            kind: "session.updated",
            subjectId: agentSessionId,
            payload: { initiatedBy: "agent", turnId: "resumed-turn", turnState: "started" }
          })
        })
      )
  })
  const endResumedTurn = (agentSessionId: string) =>
    agents.emit(agentSessionId, {
      kind: "session.updated",
      subjectId: agentSessionId,
      payload: {
        initiatedBy: "agent",
        stopReason: "end_turn",
        turnId: "resumed-turn",
        turnState: "ended"
      }
    })
  return { pauses, resumes, endResumedTurn }
}
