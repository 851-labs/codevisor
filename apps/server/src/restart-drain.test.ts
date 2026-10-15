import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { RestartDrainState, UpdateInfo, type UpdateApplyState } from "@codevisor/api"
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

const openSession = async (server: RunningCodevisorServer, title: string) => {
  const folder = join(mkdtempSync(join(tmpdir(), "codevisor-drain-")), "repo")
  mkdirSync(folder, { recursive: true })
  tempDirs.push(folder)
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

const prompt = (server: RunningCodevisorServer, sessionId: string, text: string) =>
  jsonRequest(server, `/v1/sessions/${sessionId}/prompt`, {
    body: JSON.stringify({ text }),
    method: "POST"
  })

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

  it("waits for live turns, holds new prompts, snapshots, and resumes after the restart", async () => {
    const { agents, services } = await makeServices("server-a")
    const snapshotPath = join(mkdtempSync(join(tmpdir(), "codevisor-drain-snap-")), "resume.json")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, {
      restartSnapshotPath: snapshotPath,
      updater
    })
    const sessionId = await openSession(server, "Draining")

    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    const applied = await jsonRequest(server, "/v1/update/apply", { method: "POST" })
    expect(applied.status).toBe(202)
    expect(applied.body).toMatchObject({ accepted: true, draining: true, targetBuildNumber: 200 })

    const drain = await jsonRequest(server, "/v1/restart/drain")
    expect(drain.body).toMatchObject({ state: "draining", remaining: 1 })
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      lastApply: { state: "draining", message: "Waiting for 1 chat to finish" }
    })
    expect(state.applyCalls).toBe(0)

    expect((await prompt(server, sessionId, "held prompt")).status).toBe(202)
    await waitFor(async () =>
      (await gateEvents(services, sessionId)).some((event) => field(event, "state") === "waiting")
    )
    expect(agents.prompts).toHaveLength(1)
    expect(await gateEvents(services, sessionId)).toEqual([
      { harnessId: "codevisor-server", harnessName: "Codevisor", state: "waiting" }
    ])
    expect((await jsonRequest(server, `/v1/sessions/${sessionId}/transcript`)).body).toMatchObject({
      updateGate: { harnessId: "codevisor-server", harnessName: "Codevisor" }
    })
    expect((await jsonRequest(server, `/v1/sessions/${sessionId}`)).body).toMatchObject({
      updateGate: { harnessId: "codevisor-server", harnessName: "Codevisor" }
    })

    await run(services.agents.cancel(`agent-codex-repo`))
    await waitFor(() => state.applyCalls === 1)
    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({
      state: "drained",
      remaining: 0
    })
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      lastApply: { state: "installing" }
    })
    expect(JSON.parse(readFileSync(snapshotPath, "utf8"))).toMatchObject({
      sessions: [sessionId]
    })
    expect(agents.closes).toContain("agent-codex-repo")
    expect(agents.prompts).toHaveLength(1)

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
      snapshotPath,
      JSON.stringify({ sessions: [doomed.id, archived.id, idle.id, "no-such-session", sessionId] })
    )

    const restarted = await startWithApp(services, undefined, { restartSnapshotPath: snapshotPath })
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts[1]?.[1]).toBe("held prompt")
    expect(await gateEvents(services, sessionId)).toEqual([
      { harnessId: "codevisor-server", harnessName: "Codevisor", state: "waiting" },
      { harnessId: "codevisor-server", harnessName: "Codevisor", state: "released" }
    ])
    expect(
      (await jsonRequest(restarted, `/v1/sessions/${sessionId}/transcript`)).body
    ).not.toHaveProperty("updateGate")
    expect(
      agents.loads.some(([, agentSessionId]) =>
        ["agent-doomed", "agent-archived", "agent-idle"].includes(agentSessionId)
      )
    ).toBe(false)
    expect(agents.loads.some(([, agentSessionId]) => agentSessionId === "agent-codex-repo")).toBe(
      true
    )
    expect((await jsonRequest(restarted, "/v1/restart/drain")).body).toMatchObject({
      state: "idle"
    })
    expect(() => readFileSync(snapshotPath)).toThrow()
  })

  it("interrupts the remaining turns on request", async () => {
    const { agents, services } = await makeServices("server-a")
    const server = await startWithApp(services)
    const sessionId = await openSession(server, "Interrupted")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    const malformed = await jsonRequest(server, "/v1/restart/drain", {
      body: "{not json",
      method: "POST"
    })
    expect(malformed.status).toBe(202)
    expect(malformed.body).toMatchObject({ state: "draining", remaining: 1 })
    const begun = await jsonRequest(server, "/v1/restart/drain", {
      body: JSON.stringify({ interrupt: true, timeoutMs: 60_000 }),
      method: "POST"
    })
    expect(begun.status).toBe(202)
    await waitFor(() => agents.cancellations.length === 1)
    await waitFor(
      async () => decodeDrain(await jsonRequest(server, "/v1/restart/drain")).state === "drained"
    )
  })

  it("an update apply can interrupt live turns outright", async () => {
    const { agents, services } = await makeServices("server-a")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { updater })
    const sessionId = await openSession(server, "Interrupted apply")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    expect(
      (await jsonRequest(server, "/v1/update/apply?interrupt=1", { method: "POST" })).status
    ).toBe(202)
    await waitFor(() => agents.cancellations.length === 1)
    await waitFor(() => state.applyCalls === 1)
  })

  it("cancelling a drain releases held prompts", async () => {
    const { agents, services } = await makeServices("server-a")
    const server = await startWithApp(services)
    const sessionId = await openSession(server, "Released")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    expect((await jsonRequest(server, "/v1/restart/drain", { method: "POST" })).status).toBe(202)
    expect((await prompt(server, sessionId, "held prompt")).status).toBe(202)
    await waitFor(async () =>
      (await gateEvents(services, sessionId)).some((event) => field(event, "state") === "waiting")
    )
    expect(agents.prompts).toHaveLength(1)

    const cancelled = await jsonRequest(server, "/v1/restart/drain", { method: "DELETE" })
    expect(cancelled.body).toMatchObject({ state: "idle" })
    await waitFor(async () =>
      (await gateEvents(services, sessionId)).some((event) => field(event, "state") === "released")
    )
    await run(services.agents.cancel("agent-codex-repo"))
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
    expect((await prompt(server, sessionId, "held prompt")).status).toBe(202)
    await run(services.agents.cancel("agent-codex-repo"))
    await waitFor(() => state.applyCalls === 1)
    await waitFor(() => agents.prompts.length === 2)
    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({ state: "idle" })
  })

  it("an update whose drain is cancelled never applies", async () => {
    const { agents, services } = await makeServices("server-a")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { updater })
    const sessionId = await openSession(server, "Cancelled apply")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    expect((await jsonRequest(server, "/v1/update/apply", { method: "POST" })).status).toBe(202)
    expect((await jsonRequest(server, "/v1/restart/drain", { method: "DELETE" })).status).toBe(200)
    expect((await jsonRequest(server, "/v1/restart/drain", { method: "PUT" })).status).toBe(404)
    await run(services.agents.cancel("agent-codex-repo"))
    await waitFor(async () => {
      const drain = await jsonRequest(server, "/v1/restart/drain")
      return decodeDrain(drain).remaining === 0
    })
    expect(state.applyCalls).toBe(0)
    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({ state: "idle" })
  })

  it("still refuses when asked to, and reports busy only for live turns", async () => {
    const { agents, services } = await makeServices("server-a")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { updater })
    const sessionId = await openSession(server, "Refused")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    const refused = await jsonRequest(server, "/v1/update/apply?whenBusy=refuse", {
      method: "POST"
    })
    expect(refused.status).toBe(200)
    expect(refused.body).toMatchObject({ accepted: false, reason: "busy" })
    expect(state.applyCalls).toBe(0)
    await run(services.agents.cancel("agent-codex-repo"))
  })
})
