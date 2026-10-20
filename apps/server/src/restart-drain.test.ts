import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import {
  RestartDrainState,
  TranscriptPage,
  UpdateInfo,
  type UpdateApplyState
} from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { observableFixture } from "./changes-test-support.js"
import type { CodevisorServerUpdater, RunningCodevisorServer } from "./server.js"
import {
  archiveSessionViaWorkspace,
  bodyId,
  jsonRequest,
  makeServices,
  run,
  startWithApp,
  tempDirs,
  waitFor,
  listSubjectEvents
} from "./test-support.js"
import { field } from "./unknown-values.js"

const decodeDrain = (response: { readonly body: unknown }) =>
  Schema.decodeUnknownSync(RestartDrainState)(response.body)

const makeUpdater = (behaviour: { applyFails?: boolean } = {}) => {
  const state = observableFixture({
    applyCalls: 0,
    lastApply: undefined as UpdateApplyState | undefined
  })
  const updater: CodevisorServerUpdater = {
    apply: async () => {
      state.applyCalls += 1
      if (behaviour.applyFails === true) throw new Error("download failed")
    },
    check: async (options) => ({
      channel: options?.channel ?? "stable",
      checkedAt: "2026-06-30T00:00:00.000Z",
      currentVersion: "0.1.0",
      currentBuildNumber: 100,
      latestVersion: "0.2.0",
      latestBuildNumber: 200,
      migrationState: "idle" as const,
      updateAvailable: true,
      ...(state.lastApply === undefined ? {} : { lastApply: state.lastApply })
    })
  }
  return { state, updater }
}

const statePaths = () => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-drain-state-"))
  tempDirs.push(root)
  return {
    restartSnapshotPath: join(root, "restart-resume.json"),
    pausedTurnsPath: join(root, "paused-for-update.json")
  }
}

const pausedSessionIds = (path: string): ReadonlyArray<unknown> => {
  if (!existsSync(path)) return []
  const turns = field(JSON.parse(readFileSync(path, "utf8")), "turns")
  return Array.isArray(turns) ? turns.map((turn) => field(turn, "sessionId")) : []
}

const openSession = async (server: RunningCodevisorServer, title: string, folderName = "repo") => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-drain-"))
  tempDirs.push(root)
  const folder = join(root, folderName)
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

const stop = (server: RunningCodevisorServer, sessionId: string) =>
  jsonRequest(server, `/v1/sessions/${sessionId}/cancel`, {
    body: JSON.stringify({}),
    method: "POST"
  })

const transcriptItems = async (server: RunningCodevisorServer, sessionId: string) =>
  Schema.decodeUnknownSync(TranscriptPage)(
    (await jsonRequest(server, `/v1/sessions/${sessionId}/transcript`)).body
  ).items

const lastAssistant = async (server: RunningCodevisorServer, sessionId: string) =>
  (await transcriptItems(server, sessionId)).findLast((item) => item.role === "assistant")

const userTexts = async (server: RunningCodevisorServer, sessionId: string) =>
  (await transcriptItems(server, sessionId))
    .filter((item) => item.role === "user" && item.origin === undefined)
    .map((item) => item.text)

const gateEvents = async (
  services: Awaited<ReturnType<typeof makeServices>>["services"],
  sessionId: string
) =>
  listSubjectEvents(services, sessionId)
    .filter((event) => event.kind === "session.updateGate.updated")
    .map((event) => event.payload)

describe("restart drain", () => {
  it("preserves fresh host progress after draining and rejects stale progress", async () => {
    const { services } = await makeServices("server-progress")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { updater })
    await jsonRequest(server, "/v1/update/apply", { method: "POST" })
    await waitFor(() => state.applyCalls === 1)
    const drain = decodeDrain(await jsonRequest(server, "/v1/restart/drain"))
    state.lastApply = {
      state: "installing",
      message: "Downloading…",
      progress: 0.42,
      at: drain.startedAt
    }
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      lastApply: state.lastApply
    })
    state.lastApply = { ...state.lastApply, progress: 0.75 }
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      lastApply: state.lastApply
    })
    state.lastApply = { ...state.lastApply, at: "2000-01-01T00:00:00.000Z" }
    const stale = Schema.decodeUnknownSync(UpdateInfo)(
      (await jsonRequest(server, "/v1/update")).body
    )
    expect(stale.lastApply?.message).toBe("Restarting to install the update")
    expect(stale.lastApply?.progress).toBeUndefined()
  })

  it("pauses live turns at once, holds new prompts, and continues them after the restart", async () => {
    const { agents, services } = await makeServices("server-a")
    const paths = statePaths()
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { ...paths, updater })
    const sessionId = await openSession(server, "Paused")

    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)
    expect((await prompt(server, sessionId, "queued earlier", "queue")).status).toBe(202)

    const applied = await jsonRequest(server, "/v1/update/apply", { method: "POST" })
    expect(applied.status).toBe(202)
    expect(applied.body).toMatchObject({ accepted: true, draining: true, targetBuildNumber: 200 })
    await waitFor(() => state.applyCalls === 1)

    expect(agents.cancellations).toEqual(["agent-codex-repo"])
    expect(await lastAssistant(server, sessionId)).toMatchObject({
      stopReason: "cancelled",
      stopKind: "interrupted"
    })
    expect(JSON.parse(readFileSync(paths.pausedTurnsPath, "utf8"))).toEqual({
      turns: [{ sessionId, turnId: "turn-1", pausedAt: expect.any(String) }]
    })
    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({
      state: "drained",
      remaining: 0
    })
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      lastApply: { state: "installing" }
    })

    await waitFor(async () =>
      (await gateEvents(services, sessionId)).some((event) => field(event, "state") === "waiting")
    )
    expect(agents.prompts).toHaveLength(1)
    expect((await jsonRequest(server, `/v1/sessions/${sessionId}/transcript`)).body).toMatchObject({
      updateGate: { harnessId: "codevisor-server", harnessName: "Codevisor" }
    })
    expect(JSON.parse(readFileSync(paths.restartSnapshotPath, "utf8"))).toMatchObject({
      sessions: [sessionId]
    })
    expect(agents.closes).toContain("agent-codex-repo")
    await run(server.close)

    const restarted = await startWithApp(services, undefined, paths)
    await waitFor(() => agents.prompts.length === 3)
    expect(agents.prompts.slice(1).map(([, input]) => input)).toEqual([
      "continue",
      "queued earlier"
    ])
    expect(await gateEvents(services, sessionId)).toEqual([
      { harnessId: "codevisor-server", harnessName: "Codevisor", state: "waiting" },
      { harnessId: "codevisor-server", harnessName: "Codevisor", state: "released" }
    ])
    expect(await userTexts(restarted, sessionId)).toEqual([
      "prompt until cancelled",
      "queued earlier"
    ])
    expect(existsSync(paths.pausedTurnsPath)).toBe(false)
    expect((await jsonRequest(restarted, "/v1/restart/drain")).body).toMatchObject({
      state: "idle"
    })
  })

  it("reloads snapshot sessions with held work but not idle, archived or missing ones", async () => {
    const { agents, services } = await makeServices("server-a")
    const paths = statePaths()
    const server = await startWithApp(services, undefined, paths)
    const sessionId = await openSession(server, "Held")
    await run(services.db.createPromptQueueItem(sessionId, "held prompt"))
    const project = (await run(services.db.listProjects))[0]!
    const doomed = await run(
      services.db.createSession({
        agentSessionId: "agent-doomed",
        harnessId: "codex",
        projectId: project.id,
        title: "Doomed",
        worktreeName: "ghost"
      })
    )
    await run(services.db.appendEvent("session.updated", doomed.id, { goal: { status: "active" } }))
    const idle = await run(
      services.db.createSession({
        agentSessionId: "agent-idle",
        harnessId: "codex",
        projectId: project.id,
        title: "Idle"
      })
    )
    const archived = await run(
      services.db.createSession({
        agentSessionId: "agent-archived",
        harnessId: "codex",
        projectId: project.id,
        title: "Archived"
      })
    )
    await archiveSessionViaWorkspace(services, project.id, archived.id)
    writeFileSync(
      paths.restartSnapshotPath,
      JSON.stringify({ sessions: [doomed.id, archived.id, idle.id, "no-such-session", sessionId] })
    )
    await run(server.close)

    await startWithApp(services, undefined, paths)
    await waitFor(() => agents.prompts.length === 1)
    expect(agents.prompts[0]?.[1]).toBe("held prompt")
    expect(
      agents.loads.some(([, agentSessionId]) =>
        ["agent-doomed", "agent-archived", "agent-idle"].includes(agentSessionId)
      )
    ).toBe(false)
    expect(existsSync(paths.restartSnapshotPath)).toBe(false)
  })

  it("continues only the chats the update paused, not ones the user stopped", async () => {
    const { agents, services } = await makeServices("server-a")
    const paths = statePaths()
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { ...paths, updater })
    const running = await openSession(server, "Running", "running")
    const stopped = await openSession(server, "Stopped", "stopped")
    expect((await prompt(server, running, "prompt until cancelled")).status).toBe(202)
    expect((await prompt(server, stopped, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 2)
    await stop(server, stopped)
    await waitFor(async () => (await lastAssistant(server, stopped))?.stopReason === "cancelled")

    await jsonRequest(server, "/v1/update/apply", { method: "POST" })
    await waitFor(() => state.applyCalls === 1)
    expect((await lastAssistant(server, stopped))?.stopKind).toBeUndefined()
    await run(server.close)

    await startWithApp(services, undefined, paths)
    await waitFor(() => !existsSync(paths.pausedTurnsPath))
    await waitFor(() => agents.prompts.length === 3)
    expect(agents.prompts[2]).toEqual(["agent-codex-running", "continue"])
  })

  it("a message the user sends first replaces that chat's continue", async () => {
    const { agents, services } = await makeServices("server-a")
    const paths = statePaths()
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { ...paths, updater })
    const first = await openSession(server, "First", "first")
    const second = await openSession(server, "Second", "second")
    expect((await prompt(server, first, "prompt until cancelled")).status).toBe(202)
    expect((await prompt(server, second, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 2)
    await jsonRequest(server, "/v1/update/apply", { method: "POST" })
    await waitFor(() => state.applyCalls === 1)
    await run(server.close)

    const restarted = await startWithApp(services, undefined, paths)
    expect((await prompt(restarted, second, "what happened?")).status).toBe(202)

    expect(pausedSessionIds(paths.pausedTurnsPath)).not.toContain(second)
    await waitFor(() => agents.prompts.length === 4)
    expect(agents.prompts.slice(2)).toEqual(
      expect.arrayContaining([
        ["agent-codex-first", "continue"],
        ["agent-codex-second", "what happened?"]
      ])
    )
  })

  it("cancelling a drain continues paused chats", async () => {
    const { agents, services } = await makeServices("server-a")
    const server = await startWithApp(services)
    const sessionId = await openSession(server, "Continued")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    expect((await jsonRequest(server, "/v1/restart/drain", { method: "POST" })).status).toBe(202)
    await waitFor(
      async () => decodeDrain(await jsonRequest(server, "/v1/restart/drain")).state === "drained"
    )

    const cancelled = await jsonRequest(server, "/v1/restart/drain", { method: "DELETE" })
    expect(cancelled.body).toMatchObject({ state: "idle" })
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts[1]?.[1]).toBe("continue")
  })

  it("a prompt sent while the update pauses a chat replaces its continue", async () => {
    const { agents, services } = await makeServices("server-a")
    const paths = statePaths()
    const server = await startWithApp(services, undefined, paths)
    const sessionId = await openSession(server, "Held")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)
    expect((await jsonRequest(server, "/v1/restart/drain", { method: "POST" })).status).toBe(202)
    await waitFor(
      async () => decodeDrain(await jsonRequest(server, "/v1/restart/drain")).state === "drained"
    )
    expect(pausedSessionIds(paths.pausedTurnsPath)).toEqual([sessionId])

    expect((await prompt(server, sessionId, "held prompt")).status).toBe(202)
    await waitFor(async () =>
      (await gateEvents(services, sessionId)).some((event) => field(event, "state") === "waiting")
    )
    expect(pausedSessionIds(paths.pausedTurnsPath)).toEqual([])
    expect(agents.prompts).toHaveLength(1)

    await jsonRequest(server, "/v1/restart/drain", { method: "DELETE" })
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts[1]?.[1]).toBe("held prompt")
  })

  it("reopens the gate when the updater fails after draining", async () => {
    const { agents, services } = await makeServices("server-a")
    const { state, updater } = makeUpdater({ applyFails: true })
    const server = await startWithApp(services, undefined, { updater })
    const sessionId = await openSession(server, "Failed apply")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    expect((await jsonRequest(server, "/v1/update/apply", { method: "POST" })).status).toBe(202)
    await waitFor(() => state.applyCalls === 1)
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts[1]?.[1]).toBe("continue")
    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({ state: "idle" })
  })

  it("an update whose drain is cancelled never applies", async () => {
    const { agents, services } = await makeServices("server-a")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { updater })
    const sessionId = await openSession(server, "Cancelled apply")
    expect((await prompt(server, sessionId, "slow prompt")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    expect((await jsonRequest(server, "/v1/update/apply", { method: "POST" })).status).toBe(202)
    await waitFor(() => agents.cancellations.length === 1)
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      lastApply: { state: "draining", message: "Pausing 1 chat for the update" }
    })
    expect((await prompt(server, sessionId, "while pausing")).body).toMatchObject({
      delivered: "queued",
      steerDeclined: true
    })
    expect((await jsonRequest(server, "/v1/restart/drain", { method: "DELETE" })).status).toBe(200)
    expect((await jsonRequest(server, "/v1/restart/drain", { method: "PUT" })).status).toBe(404)
    agents.releasePrompt()
    await waitFor(async () => {
      const drain = await jsonRequest(server, "/v1/restart/drain")
      return decodeDrain(drain).remaining === 0
    })
    expect(state.applyCalls).toBe(0)
    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({ state: "idle" })
  })
})
