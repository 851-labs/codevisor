import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import type { CodevisorServerUpdater, RunningCodevisorServer } from "./server.js"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs,
  waitFor
} from "./test-support.js"

/// The restart drain end to end: an update accepted while a chat is mid-turn
/// waits for it, holds anything sent meanwhile, snapshots the live sessions,
/// and the next boot brings them back and dispatches the held prompts.

const makeUpdater = (behaviour: { applyFails?: boolean } = {}) => {
  const state = { applyCalls: 0 }
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
      updateAvailable: true
    })
  }
  return { state, updater }
}

const openSession = async (server: RunningCodevisorServer, title: string) => {
  const folder = join(mkdtempSync(join(tmpdir(), "codevisor-drain-")), "repo")
  mkdirSync(folder, { recursive: true })
  tempDirs.push(folder)
  const project = (
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder }),
      method: "POST"
    })
  ).body as { readonly id: string }
  const session = (
    await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ harnessId: "codex", projectId: project.id, title }),
      method: "POST"
    })
  ).body as { readonly id: string }
  return session.id
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
  (await run(services.db.listSubjectEvents(sessionId)))
    .filter((event) => event.kind === "session.updateGate.updated")
    .map((event) => event.payload as { harnessId: string; state: string })

describe("restart drain", () => {
  it("waits for live turns, holds new prompts, snapshots, and resumes after the restart", async () => {
    const { agents, services } = await makeServices("server-a")
    const snapshotPath = join(mkdtempSync(join(tmpdir(), "codevisor-drain-snap-")), "resume.json")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, {
      restartSnapshotPath: snapshotPath,
      updater
    })
    runningServers.push(server)
    const sessionId = await openSession(server, "Draining")

    // A turn is in flight when the update arrives.
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    const applied = await jsonRequest(server, "/v1/update/apply", { method: "POST" })
    expect(applied.status).toBe(202)
    expect(applied.body).toMatchObject({ accepted: true, draining: true, targetBuildNumber: 200 })

    // Draining: the update state says so, and nothing has been applied yet.
    const drain = await jsonRequest(server, "/v1/restart/drain")
    expect(drain.body).toMatchObject({ state: "draining", remaining: 1 })
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      lastApply: { state: "draining", message: "Waiting for 1 chat to finish" }
    })
    expect(state.applyCalls).toBe(0)

    // A prompt sent meanwhile is accepted and held, with the transcript
    // marker clients render as "waiting for update".
    expect((await prompt(server, sessionId, "held prompt")).status).toBe(202)
    await new Promise((resolve) => setTimeout(resolve, 150))
    expect(agents.prompts).toHaveLength(1)
    expect(await gateEvents(services, sessionId)).toEqual([
      { harnessId: "codevisor-server", harnessName: "Codevisor", state: "waiting" }
    ])

    // The turn ends → the drain completes, sessions are snapshotted and
    // their processes closed, and only then does the updater run.
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
    // Still gated after the drain: nothing dispatches until the restart.
    expect(agents.prompts).toHaveLength(1)

    // Sessions the snapshot may also name: one whose worktree is gone (its
    // resume fails and is logged), one archived since, and one that no
    // longer exists. None of them blocks the rest.
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
    const archived = await run(
      services.db.createSession({
        agentSessionId: "agent-archived",
        harnessId: "codex",
        projectId: project.id,
        title: "Archived"
      })
    )
    await run(services.db.updateSession(archived.id, { isArchived: true }))
    writeFileSync(
      snapshotPath,
      JSON.stringify({ sessions: [doomed.id, archived.id, "no-such-session", sessionId] })
    )

    // The "restarted" server consumes the snapshot: the session reconnects
    // through its harness's native resume and the held prompt dispatches.
    const restarted = await startWithApp(services, undefined, { restartSnapshotPath: snapshotPath })
    runningServers.push(restarted)
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts[1]?.[1]).toBe("held prompt")
    expect(
      agents.loads.some(([, agentSessionId]) =>
        ["agent-doomed", "agent-archived"].includes(agentSessionId)
      )
    ).toBe(false)
    expect(agents.loads.some(([, agentSessionId]) => agentSessionId === "agent-codex-repo")).toBe(
      true
    )
    // Consumed: a crash mid-resume must not loop on the same snapshot.
    expect((await jsonRequest(restarted, "/v1/restart/drain")).body).toMatchObject({
      state: "idle"
    })
    expect(() => readFileSync(snapshotPath)).toThrow()
  })

  it("interrupts the remaining turns on request", async () => {
    const { agents, services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)
    const sessionId = await openSession(server, "Interrupted")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    // A malformed body still begins the drain with defaults.
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
      async () =>
        ((await jsonRequest(server, "/v1/restart/drain")).body as { state: string }).state ===
        "drained"
    )
  })

  it("an update apply can interrupt live turns outright", async () => {
    const { agents, services } = await makeServices("server-a")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { updater })
    runningServers.push(server)
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
    runningServers.push(server)
    const sessionId = await openSession(server, "Released")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    expect((await jsonRequest(server, "/v1/restart/drain", { method: "POST" })).status).toBe(202)
    expect((await prompt(server, sessionId, "held prompt")).status).toBe(202)
    await new Promise((resolve) => setTimeout(resolve, 100))
    expect(agents.prompts).toHaveLength(1)

    // Abandon the update: the gate reopens and the held session is told so.
    const cancelled = await jsonRequest(server, "/v1/restart/drain", { method: "DELETE" })
    expect(cancelled.body).toMatchObject({ state: "idle" })
    await waitFor(async () =>
      (await gateEvents(services, sessionId)).some((event) => event.state === "released")
    )
    // The live turn is still running, so the re-drain holds behind it; once
    // that turn ends the held prompt dispatches normally.
    await run(services.agents.cancel("agent-codex-repo"))
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts[1]?.[1]).toBe("held prompt")
  })

  it("reopens the gate when the updater fails after draining", async () => {
    const { agents, services } = await makeServices("server-a")
    const { state, updater } = makeUpdater({ applyFails: true })
    const server = await startWithApp(services, undefined, { updater })
    runningServers.push(server)
    const sessionId = await openSession(server, "Failed apply")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    expect((await jsonRequest(server, "/v1/update/apply", { method: "POST" })).status).toBe(202)
    expect((await prompt(server, sessionId, "held prompt")).status).toBe(202)
    await run(services.agents.cancel("agent-codex-repo"))
    await waitFor(() => state.applyCalls === 1)
    // apply threw → cancel → the held prompt dispatches.
    await waitFor(() => agents.prompts.length === 2)
    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({ state: "idle" })
  })

  it("an update whose drain is cancelled never applies", async () => {
    const { agents, services } = await makeServices("server-a")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { updater })
    runningServers.push(server)
    const sessionId = await openSession(server, "Cancelled apply")
    expect((await prompt(server, sessionId, "prompt until cancelled")).status).toBe(202)
    await waitFor(() => agents.prompts.length === 1)

    expect((await jsonRequest(server, "/v1/update/apply", { method: "POST" })).status).toBe(202)
    expect((await jsonRequest(server, "/v1/restart/drain", { method: "DELETE" })).status).toBe(200)
    // Unsupported methods on the drain route fall through to 404.
    expect((await jsonRequest(server, "/v1/restart/drain", { method: "PUT" })).status).toBe(404)
    await run(services.agents.cancel("agent-codex-repo"))
    await new Promise((resolve) => setTimeout(resolve, 100))
    expect(state.applyCalls).toBe(0)
    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({ state: "idle" })
  })

  it("still refuses when asked to, and reports busy only for live turns", async () => {
    const { agents, services } = await makeServices("server-a")
    const { state, updater } = makeUpdater()
    const server = await startWithApp(services, undefined, { updater })
    runningServers.push(server)
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
