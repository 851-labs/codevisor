import { mkdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { jsonRequest } from "../test-support.js"
import { setUpWorkspace } from "./session-test-support.js"

describe("session catalog routes", () => {
  it("lists harnesses, rescans, and discovers capabilities", async () => {
    const { agents, server, workspace, workspaceFolder, workspaceRoot } = await setUpWorkspace()
    const noModesFolder = join(workspaceRoot, "no-modes")
    const capabilityFailFolder = join(workspaceRoot, "capability-fail")
    const cwdFile = join(workspaceRoot, "cwd-file")
    mkdirSync(noModesFolder)
    mkdirSync(capabilityFailFolder)
    writeFileSync(cwdFile, "")
    const badJson = await fetch(`${server.url}/v1/projects`, {
      body: "{",
      headers: { "Content-Type": "application/json" },
      method: "POST"
    })
    expect(badJson.status).toBe(400)
    expect((await jsonRequest(server, "/v1/missing")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/not-sessions/session-a/queue/item-a")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/projects")).body).toMatchObject([{ id: workspace.id }])

    expect((await jsonRequest(server, "/v1/harnesses")).body).toMatchObject([
      { id: "codex", enabled: true, installHint: "npm install -g @openai/codex" }
    ])

    // Rescan re-resolves the runtime environment, then returns the fresh list.
    const rescanResponse = await jsonRequest(server, "/v1/harnesses/rescan", { method: "POST" })
    expect(rescanResponse.status).toBe(200)
    expect(rescanResponse.body).toMatchObject([{ id: "codex", enabled: true }])
    expect(agents.environmentRefreshes).toHaveLength(1)

    // Native agent sessions come from the harness's own store via the runtime.
    expect((await jsonRequest(server, "/v1/harnesses/codex/agent-sessions")).body).toEqual([
      { sessionId: "native-1", cwd: "/repo/native", title: "Old codex chat" }
    ])
    expect((await jsonRequest(server, "/v1/harnesses/gemini/agent-sessions")).body).toEqual([])
    const capabilitiesResponse = await jsonRequest(
      server,
      `/v1/capabilities?cwd=${encodeURIComponent(workspaceFolder)}`
    )
    expect(capabilitiesResponse.body).toMatchObject({
      harnesses: [
        {
          harness: { id: "codex" },
          modes: { currentModeId: "default" },
          configOptions: [
            { category: "model", currentValue: "gpt-5", id: "model" },
            { category: "thought_level", currentValue: "medium", id: "reasoning" }
          ],
          supportsGoals: true
        }
      ]
    })
    expect(agents.inspections).toEqual([["codex", workspaceFolder]])
    expect(agents.inspectionConfigs).toEqual([undefined])
    agents.inspections.splice(0)
    agents.inspectionConfigs.splice(0)
    expect(
      (
        await jsonRequest(
          server,
          `/v1/capabilities?cwd=${encodeURIComponent(workspaceFolder)}&harnessId=missing`
        )
      ).body
    ).toEqual({ harnesses: [] })
    expect(agents.inspections).toEqual([])
    expect(
      (
        await jsonRequest(
          server,
          `/v1/capabilities?cwd=${encodeURIComponent(workspaceFolder)}&harnessId=codex`
        )
      ).body
    ).toMatchObject({ harnesses: [{ harness: { id: "codex" } }] })
    expect(agents.inspections).toEqual([["codex", workspaceFolder]])
    expect(
      (
        await jsonRequest(
          server,
          `/v1/capabilities?cwd=${encodeURIComponent(workspaceFolder)}&harnessId=codex&config.model=gpt-next`
        )
      ).body
    ).toMatchObject({
      harnesses: [
        {
          configOptions: [
            { currentValue: "gpt-next", id: "model" },
            { currentValue: "high", id: "reasoning" }
          ]
        }
      ]
    })
    expect(agents.inspectionConfigs.at(-1)).toEqual({ model: "gpt-next" })
    expect((await jsonRequest(server, "/v1/capabilities")).body).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    const missingCwdCapabilities = await jsonRequest(
      server,
      "/v1/capabilities?cwd=%2Ftmp%2Fmissing-codevisor-workspace"
    )
    expect(missingCwdCapabilities.body).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    expect(
      (
        missingCwdCapabilities.body as {
          readonly harnesses: ReadonlyArray<{
            readonly configOptions: ReadonlyArray<{ readonly id: string }>
          }>
        }
      ).harnesses[0]?.configOptions.map((option) => option.id)
    ).toContain("model")
    expect(agents.inspections.at(-1)).toEqual(["codex", tmpdir()])
    expect(
      (await jsonRequest(server, `/v1/capabilities?cwd=${encodeURIComponent(cwdFile)}`)).body
    ).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    expect(agents.inspections.at(-1)).toEqual(["codex", tmpdir()])
    expect(
      (await jsonRequest(server, `/v1/capabilities?cwd=${encodeURIComponent(noModesFolder)}`)).body
    ).toMatchObject({
      harnesses: [{ configOptions: [], harness: { id: "codex" } }]
    })
    expect(
      (
        await jsonRequest(
          server,
          `/v1/capabilities?cwd=${encodeURIComponent(capabilityFailFolder)}`
        )
      ).body
    ).toMatchObject({
      harnesses: [{ configOptions: [], harness: { id: "codex" } }]
    })
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex", {
          body: JSON.stringify({ enabled: false }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ id: "codex", enabled: false })
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/missing", {
          body: JSON.stringify({ enabled: true }),
          method: "PATCH"
        })
      ).status
    ).toBe(404)
  })
})
