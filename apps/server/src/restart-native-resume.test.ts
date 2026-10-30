import { existsSync, mkdirSync, mkdtempSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { TranscriptPage } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { updateResumeNotice } from "./restart-notice.js"
import { pauseForUpdate, restartStatePaths, withNativeTurnResume } from "./restart-test-support.js"
import type { RunningCodevisorServer } from "./server.js"
import {
  bodyId,
  jsonRequest,
  makeServices,
  run,
  startWithApp,
  tempDirs,
  waitFor
} from "./test-support.js"

const openSession = async (server: RunningCodevisorServer, title: string) => {
  const folder = join(mkdtempSync(join(tmpdir(), "codevisor-native-resume-")), "repo")
  tempDirs.push(folder)
  mkdirSync(folder, { recursive: true })
  const projectId = bodyId(
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder }),
      method: "POST"
    })
  )
  return bodyId(
    await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ harnessId: "codex", projectId, title }),
      method: "POST"
    })
  )
}

const prompt = (
  server: RunningCodevisorServer,
  sessionId: string,
  text: string,
  delivery?: "queue"
) =>
  jsonRequest(server, `/v1/sessions/${sessionId}/prompt`, {
    body: JSON.stringify({ text, delivery }),
    method: "POST"
  })

const transcriptPage = async (server: RunningCodevisorServer, sessionId: string) =>
  Schema.decodeUnknownSync(TranscriptPage)(
    (await jsonRequest(server, `/v1/sessions/${sessionId}/transcript`)).body
  )

describe("native resume after an update restart", () => {
  it("resumes a paused turn through the harness, with no new message, then sends work queued before the update", async () => {
    const { agents, services } = await makeServices("server-a")
    const native = withNativeTurnResume(agents)
    const paths = restartStatePaths()
    const server = await startWithApp(services, undefined, paths)
    const sessionId = await openSession(server, "Paused")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)
    expect((await prompt(server, sessionId, "queued earlier", "queue")).status).toBe(202)

    await pauseForUpdate(server)
    expect(native.pauses).toEqual(["agent-codex-repo"])
    expect(JSON.parse(readFileSync(paths.pausedTurnsPath, "utf8"))).toEqual({
      turns: [
        { sessionId, turnId: "turn-1", pausedAt: expect.any(String), resumesInterruptedTurn: true }
      ]
    })
    await run(server.close)

    await startWithApp(services, undefined, paths)
    await waitFor(() => !existsSync(paths.pausedTurnsPath))
    expect(native.resumes).toEqual([{ notice: updateResumeNotice([]), stoppedTasks: [] }])
    expect(agents.prompts).toHaveLength(1)

    await native.endResumedTurn("agent-codex-repo")
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts[1]).toEqual(["agent-codex-repo", "queued earlier"])
  })

  it("pauses a turn waiting on a question with a plain cancel, so the question stays open", async () => {
    const { agents, services } = await makeServices("server-a")
    const native = withNativeTurnResume(agents)
    const server = await startWithApp(services, undefined, restartStatePaths())
    const sessionId = await openSession(server, "Asking")
    expect((await prompt(server, sessionId, "ask until cancelled")).status).toBe(202)
    await waitFor(
      async () => (await transcriptPage(server, sessionId)).pendingQuestion !== undefined
    )

    await pauseForUpdate(server)

    expect(native.pauses).toEqual([])
    expect(agents.cancellations).toEqual(["agent-codex-repo"])
    expect((await transcriptPage(server, sessionId)).pendingQuestion).toBeDefined()
  })
})
