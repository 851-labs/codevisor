import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { SessionConfigOption } from "@codevisor/api"
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

    const picked = await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
      body: JSON.stringify({ configId: "model", value: "model-saved" }),
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
    expect(Object.values(saved)).not.toContain("model-legacy")
  })
})
