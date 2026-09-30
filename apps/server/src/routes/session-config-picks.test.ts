import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { SessionConfigOption, SessionSummary } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import {
  configSelectionsFromTestOptions,
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs
} from "../test-support.js"

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
    runningServers.push(server)

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
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual({
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
    const restored = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
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
    const fallback = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
    expect(agents.configs).toEqual([])
    expect(configSelectionsFromTestOptions(fallback.configOptions)).toEqual({
      model: "model-default",
      reasoning: "low",
      speed: "standard",
      tone: "brief"
    })
    // The runtime's fallback never replaces the picks: they stay saved, and
    // the ones it does not offer are reported as unavailable. An option the
    // runtime lacks altogether is kept, and an earlier verdict on it stands.
    const { session: afterFallback } = (await jsonRequest(server, `/v1/sessions/${session.id}`))
      .body as { readonly session: SessionSummary }
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

    // Picking the option answers its unavailable mark; a model pick also
    // settles the options that depend on the model.
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
    const transientFallback = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
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
    runningServers.push(server)

    const opened = await jsonRequest(server, `/v1/sessions/${session.id}/connect`, {
      method: "POST"
    })
    expect(opened.status).toBe(200)
    expect((opened.body as { readonly configOptions: unknown }).configOptions).toEqual([])
    // Nothing to validate against, so nothing is applied — and, above all,
    // nothing is overwritten.
    expect(agents.configs).toEqual([])
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual(saved)
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
    runningServers.push(server)

    const picked = await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "model", value: "model-saved" }),
      method: "POST"
    })
    expect(picked.status).toBe(202)
    // No runtime snapshot exists yet, so there is nothing to reflect it onto.
    expect(picked.body).toEqual({ configId: "model", configOptions: [] })
    expect(agents.loads).toEqual([])
    expect(agents.configs).toEqual([])
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual({
      model: "model-saved",
      reasoning: "low"
    })

    // The next connect applies the recorded pick against the live list.
    const restored = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
    // The process starts on the saved picks rather than its default.
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
    runningServers.push(server)
    // Connect once so a runtime snapshot is persisted, then retire the process.
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(200)
    await run(services.agents.closeAgentSession("agent-session-config-closed"))
    agents.configs.splice(0)

    // A drifted id lands on the entry the last known list offers.
    const picked = await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "model", value: "model-saved-legacy" }),
      method: "POST"
    })
    expect(picked.status).toBe(202)
    expect(agents.configs).toEqual([])
    const body = picked.body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
    expect(configSelectionsFromTestOptions(body.configOptions)).toMatchObject({
      model: "model-saved",
      reasoning: "low"
    })
    expect((await run(services.db.getSessionConfigSelections(session.id))).model).toBe(
      "model-saved"
    )

    // A value that list does not know is still the user's pick: the list may
    // be stale, and the next restore judges it against the live runtime.
    await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "model", value: "model-next" }),
      method: "POST"
    })
    expect((await run(services.db.getSessionConfigSelections(session.id))).model).toBe("model-next")
  })

  it("records a pick for a chat with no agent session or usable snapshot", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    // A snapshot that carries no option list is not an answer either.
    await run(services.db.saveSessionRuntimeState(session.id, { sessionId: "agent-none" }))
    const server = await startWithApp(services)
    runningServers.push(server)

    const picked = await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "reasoning", value: "high" }),
      method: "POST"
    })
    expect(picked.status).toBe(202)
    expect(picked.body).toEqual({ configId: "reasoning", configOptions: [] })
    expect(agents.loads).toEqual([])
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual({
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
    runningServers.push(server)

    const restored = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }

    // Already the runtime's value: nothing to send, and the saved id migrates.
    expect(agents.configs).toEqual([])
    expect(configSelectionsFromTestOptions(restored.configOptions).model).toBe("model-default")
    expect((await run(services.db.getSessionConfigSelections(session.id))).model).toBe(
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
    runningServers.push(server)

    const restored = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }

    expect(agents.configs).toEqual([
      [session.agentSessionId, "model", "model-saved"],
      [session.agentSessionId, "reasoning", "high"]
    ])
    expect(configSelectionsFromTestOptions(restored.configOptions)).toMatchObject({
      model: "model-saved",
      reasoning: "high"
    })
    const saved = await run(services.db.getSessionConfigSelections(session.id))
    expect(saved.model).toBe("model-saved")
  })
})
