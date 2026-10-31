import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, SessionConfigOption, SessionSummary } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { dependencyConfigOptions } from "../test-support-config-options.js"
import {
  configSelectionsFromTestOptions,
  jsonRequest,
  listSubjectEvents,
  makeServices,
  run,
  startWithApp,
  tempDirs
} from "../test-support.js"
import { field } from "./response-test-support.js"

const ConfigOptions = Schema.Struct({ configOptions: Schema.Array(SessionConfigOption) })

const SessionEnvelope = Schema.Struct({ session: SessionSummary })

describe("session configuration picks", () => {
  it("persists session config and restores model before dependent reasoning and speed", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-session-config"
      })
    )
    const server = await startWithApp(services)

    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(200)
    for (const [configId, value] of [
      ["model", "model-saved"],
      ["reasoning", "high"],
      ["speed", "fast"],
      ["tone", "detailed"]
    ] as const) {
      expect(
        (
          await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
            body: JSON.stringify({ configId, value }),
            method: "POST"
          })
        ).status
      ).toBe(202)
    }
    expect((await run(services.db.getSessionSummary(session.id))).configSelections).toEqual({
      model: "model-saved",
      reasoning: "high",
      speed: "fast",
      tone: "detailed"
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: {
        configSelections: {
          model: "model-saved",
          reasoning: "high",
          speed: "fast",
          tone: "detailed"
        }
      }
    })

    agents.configs.splice(0)
    const restored = decode(ConfigOptions)(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).body
    )
    expect(agents.configs).toEqual([
      [session.agentSessionId, "model", "model-saved"],
      [session.agentSessionId, "reasoning", "high"],
      [session.agentSessionId, "speed", "fast"],
      [session.agentSessionId, "tone", "detailed"]
    ])
    expect(configSelectionsFromTestOptions(restored.configOptions)).toEqual({
      model: "model-saved",
      reasoning: "high",
      speed: "fast",
      tone: "detailed"
    })

    await run(
      services.db.replaceSessionConfigSelections(
        session.id,
        {
          model: "model-removed",
          reasoning: "high",
          speed: "fast",
          tone: "tone-removed",
          "zzz-removed": "unavailable"
        },
        { "zzz-removed": "unavailable" }
      )
    )
    agents.configs.splice(0)
    const fallback = decode(ConfigOptions)(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).body
    )
    expect(agents.configs).toEqual([])
    expect(configSelectionsFromTestOptions(fallback.configOptions)).toEqual({
      model: "model-default",
      reasoning: "low",
      speed: "standard",
      tone: "brief"
    })
    const { session: afterFallback } = decode(SessionEnvelope)(
      (await jsonRequest(server, `/v1/sessions/${session.id}`)).body
    )
    expect(afterFallback.configSelections).toEqual({
      model: "model-removed",
      reasoning: "high",
      speed: "fast",
      tone: "tone-removed",
      "zzz-removed": "unavailable"
    })
    expect(afterFallback.unavailableConfigSelections).toEqual({
      model: "model-removed",
      reasoning: "high",
      speed: "fast",
      tone: "tone-removed",
      "zzz-removed": "unavailable"
    })

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
          body: JSON.stringify({ configId: "model", value: "model-default" }),
          method: "POST"
        })
      ).status
    ).toBe(202)
    const afterPick = await run(services.db.getSessionSummary(session.id))
    expect(afterPick.configSelections).toEqual({
      model: "model-default",
      reasoning: "low",
      speed: "standard",
      tone: "tone-removed",
      "zzz-removed": "unavailable"
    })
    expect(afterPick.unavailableConfigSelections).toEqual({
      tone: "tone-removed",
      "zzz-removed": "unavailable"
    })

    await run(
      services.db.replaceSessionConfigSelections(session.id, {
        model: "model-saved"
      })
    )
    agents.configFailures.push(["agent-session-config", "model", "model-saved"])
    const transientFallback = decode(ConfigOptions)(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).body
    )
    expect(configSelectionsFromTestOptions(transientFallback.configOptions).model).toBe(
      "model-default"
    )
    const afterFailure = await run(services.db.getSessionSummary(session.id))
    expect(afterFailure.configSelections).toEqual({ model: "model-saved" })
    expect(afterFailure.unavailableConfigSelections).toBeUndefined()
  })

  it("keeps saved config selections when a session opens with no config options", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-no-config-options-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "claude-code",
        agentSessionId: "agent-no-config-options"
      })
    )
    const saved = { effort: "high", model: "opus[1m]", speed: "standard" }
    await run(services.db.replaceSessionConfigSelections(session.id, saved))
    const server = await startWithApp(services)

    const opened = await jsonRequest(server, `/v1/sessions/${session.id}/connect`, {
      method: "POST"
    })
    expect(opened.status).toBe(200)
    expect(field(opened.body, "configOptions")).toEqual([])
    expect(agents.configs).toEqual([])
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { configSelections: saved }
    })
  })

  it("records a pick without starting the agent when no runtime is loaded", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-session-config-deferred"
      })
    )
    await run(
      services.db.replaceSessionConfigSelections(session.id, {
        model: "model-default",
        reasoning: "low"
      })
    )
    const server = await startWithApp(services)

    const picked = await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "model", value: "model-saved" }),
      method: "POST"
    })
    expect(picked.status).toBe(202)
    expect(picked.body).toEqual({ configId: "model", configOptions: [] })
    expect(agents.loads).toEqual([])
    expect(agents.configs).toEqual([])
    expect((await run(services.db.getSessionSummary(session.id))).configSelections).toEqual({
      model: "model-saved",
      reasoning: "low"
    })

    const restored = decode(ConfigOptions)(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).body
    )
    expect(agents.startSelections).toEqual([{ model: "model-saved", reasoning: "low" }])
    expect(agents.configs).toEqual([[session.agentSessionId, "model", "model-saved"]])
    expect(configSelectionsFromTestOptions(restored.configOptions).model).toBe("model-saved")
  })

  it("reflects a deferred pick onto the last runtime snapshot once the runtime is gone", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-session-config-closed"
      })
    )
    const server = await startWithApp(services)
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(200)
    await run(services.agents.closeAgentSession("agent-session-config-closed"))
    agents.configs.splice(0)

    const picked = await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "model", value: "model-saved-legacy" }),
      method: "POST"
    })
    expect(picked.status).toBe(202)
    expect(agents.configs).toEqual([])
    const body = decode(ConfigOptions)(picked.body)
    expect(configSelectionsFromTestOptions(body.configOptions)).toMatchObject({
      model: "model-saved",
      reasoning: "low"
    })
    expect((await run(services.db.getSessionSummary(session.id))).configSelections?.model).toBe(
      "model-saved"
    )

    await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "model", value: "model-next" }),
      method: "POST"
    })
    expect((await run(services.db.getSessionSummary(session.id))).configSelections?.model).toBe(
      "model-next"
    )
  })

  it("publishes a pick made with no runtime loaded to every client", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-session-config-offline"
      })
    )
    const server = await startWithApp(services)
    await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "model", value: "model-saved" }),
      method: "POST"
    })
    await run(services.agents.closeAgentSession("agent-session-config-offline"))
    const since = listSubjectEvents(services, session.id).at(-1)?.subjectRevision ?? 0

    await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "model", value: "model-default" }),
      method: "POST"
    })

    const runtime = decode(ConfigOptions)(await run(services.db.getSessionRuntimeState(session.id)))
    expect(configSelectionsFromTestOptions(runtime.configOptions).model).toBe("model-default")
    const published = listSubjectEvents(services, session.id, since).map((event) => event.payload)
    expect(published).toContainEqual(
      expect.objectContaining({
        configOptions: expect.arrayContaining([
          expect.objectContaining({ id: "model", currentValue: "model-default" })
        ])
      })
    )
    expect(published).toContainEqual(
      expect.objectContaining({
        configSelections: expect.objectContaining({ model: "model-default" })
      })
    )
  })

  it("replaces an outdated option report when a runtime starts on the saved picks", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-starts-on-saved-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-session-config-starts-on-saved"
      })
    )
    const server = await startWithApp(services)
    await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    await agents.emit("agent-session-config-starts-on-saved", {
      kind: "session.updated",
      subjectId: "agent-session-config-starts-on-saved",
      payload: { configOptions: dependencyConfigOptions("model-default") }
    })
    await run(services.agents.closeAgentSession("agent-session-config-starts-on-saved"))
    await run(services.db.replaceSessionConfigSelections(session.id, { model: "model-saved" }))
    agents.configs.splice(0)

    await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })

    expect(agents.configs).toEqual([])
    const runtime = decode(ConfigOptions)(await run(services.db.getSessionRuntimeState(session.id)))
    expect(configSelectionsFromTestOptions(runtime.configOptions).model).toBe("model-saved")
  })

  it("records a pick for a chat with no agent session or usable snapshot", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await run(services.db.saveSessionRuntimeState(session.id, { sessionId: "agent-none" }))
    const server = await startWithApp(services)

    const picked = await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "reasoning", value: "high" }),
      method: "POST"
    })
    expect(picked.status).toBe(202)
    expect(picked.body).toEqual({ configId: "reasoning", configOptions: [] })
    expect(agents.loads).toEqual([])
    expect((await run(services.db.getSessionSummary(session.id))).configSelections).toEqual({
      reasoning: "high"
    })
  })

  it("keeps the runtime's current value when a legacy id reconciles onto it", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-session-config-current"
      })
    )
    await run(
      services.db.replaceSessionConfigSelections(session.id, { model: "model-default-legacy" })
    )
    const server = await startWithApp(services)

    const restored = decode(ConfigOptions)(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).body
    )

    expect(agents.configs).toEqual([])
    expect(configSelectionsFromTestOptions(restored.configOptions).model).toBe("model-default")
    expect((await run(services.db.getSessionSummary(session.id))).configSelections?.model).toBe(
      "model-default"
    )
  })

  it("restores a legacy model id through the provider's reconciliation", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-session-config-legacy"
      })
    )
    await run(
      services.db.replaceSessionConfigSelections(session.id, {
        model: "model-saved-legacy",
        reasoning: "high"
      })
    )
    const server = await startWithApp(services)

    const restored = decode(ConfigOptions)(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).body
    )

    expect(agents.configs).toEqual([
      [session.agentSessionId, "model", "model-saved"],
      [session.agentSessionId, "reasoning", "high"]
    ])
    expect(configSelectionsFromTestOptions(restored.configOptions)).toMatchObject({
      model: "model-saved",
      reasoning: "high"
    })
    const saved = (await run(services.db.getSessionSummary(session.id))).configSelections
    expect(saved?.model).toBe("model-saved")
  })
})
