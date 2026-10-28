import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, StartedSandboxAgent } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { readyHarness, sandboxHarness } from "../infra/sandbox-test-support.js"
import { jsonRequest, startWithApp, tempDirs } from "../test-support.js"
import { idOf } from "./response-test-support.js"

const sandboxServer = async (callerSelections?: Record<string, string>) => {
  const harness = await sandboxHarness({ onCurl: readyHarness("codex") })
  const server = await startWithApp(
    { ...harness.services, sandboxes: { sandboxes: harness.machines, catalog: harness.catalog } },
    undefined,
    { id: "server-owner" }
  )
  const post = (path: string, body: unknown) =>
    jsonRequest(server, path, { method: "POST", body: JSON.stringify(body) })
  const caller = await callerIn(post, callerSelections)
  const startAgent = (fields: Record<string, unknown>) =>
    post("/v1/agents", {
      prompt: "Fix the flaky test",
      title: "Fix flake",
      isolation: "worktree",
      callerAgentId: caller,
      project: harness.storedProjectId,
      ...fields
    })
  return { harness, server, caller, startAgent }
}

const callerIn = async (
  post: (path: string, body: unknown) => Promise<{ readonly body: unknown }>,
  configSelections?: Record<string, string>
): Promise<string> => {
  const folderPath = mkdtempSync(join(tmpdir(), "codevisor-sandbox-caller-"))
  tempDirs.push(folderPath)
  const project = idOf((await post("/v1/projects", { folderPath, name: "Caller" })).body)
  const session = { projectId: project, harnessId: "codex", configSelections }
  return idOf((await post("/v1/sessions", session)).body)
}

describe("POST /v1/agents with a sandbox profile", () => {
  it("answers at once with the new sandbox, then starts the agent on it for the caller", async () => {
    const { harness, caller, startAgent } = await sandboxServer()

    const response = await startAgent({ sandboxProfile: "ubuntu sandbox", labels: { k: "v" } })
    await harness.machines.settled()

    expect(response.status).toBe(202)
    expect(decode(StartedSandboxAgent)(response.body)).toEqual({
      sandboxId: "id-1",
      title: "Fix flake",
      projectId: harness.storedProjectId,
      profileId: "profile-1",
      state: "creating"
    })
    expect(await harness.machines.get("id-1")).toMatchObject({
      name: "Fix flake",
      state: "ready",
      agentId: "remote-agent",
      agent: { harness: "codex", labels: { k: "v" }, parentSessionId: caller }
    })
    expect(harness.toolCalls.at(-1)).toMatchObject({
      tool: "codevisor.agents.start",
      sessionId: caller
    })
  })

  it("passes the caller's model along for the same harness, and a chosen model as is", async () => {
    const { harness, startAgent } = await sandboxServer({ model: "gpt-6" })

    await startAgent({ sandboxProfile: "profile-1" })
    await startAgent({ sandboxProfile: "profile-1", harness: "claude-code" })
    await startAgent({ sandboxProfile: "profile-1", model: "gpt-6-mini" })
    await harness.machines.settled()

    const agents = (await harness.machines.list()).map((machine) => machine.agent)
    expect(agents.map((agent) => [agent?.harness, agent?.model])).toEqual([
      ["codex", "gpt-6"],
      ["claude-code", undefined],
      ["codex", "gpt-6-mini"]
    ])
  })

  it("starts an agent with no caller as a plain chat on the sandbox", async () => {
    const { harness, startAgent } = await sandboxServer()

    const response = await startAgent({
      sandboxProfile: "profile-1",
      callerAgentId: undefined,
      harness: "codex"
    })
    await harness.machines.settled()

    expect(response.status).toBe(202)
    expect((await harness.machines.get("id-1")).agent?.parentSessionId).toBeUndefined()
  })

  it("names the profiles there are when none matches", async () => {
    const { harness, startAgent } = await sandboxServer()

    const unknown = await startAgent({ sandboxProfile: "gpu box" })
    await harness.settings.removeProfile("profile-1")
    const none = await startAgent({ sandboxProfile: "gpu box" })

    expect(unknown).toMatchObject({
      status: 422,
      body: {
        error: 'No sandbox profile matches "gpu box". Profiles: Ubuntu Sandbox (profile-1)'
      }
    })
    expect(none).toMatchObject({
      status: 422,
      body: { error: "There are no sandbox profiles yet; create one first" }
    })
  })

  it("answers 501 when the server has no sandbox support", async () => {
    const { harness } = await sandboxServer()
    const bare = await startWithApp(harness.services, undefined, { id: "server-owner" })
    const caller = await callerIn((path, body) =>
      jsonRequest(bare, path, { method: "POST", body: JSON.stringify(body) })
    )

    const response = await jsonRequest(bare, "/v1/agents", {
      method: "POST",
      body: JSON.stringify({
        prompt: "Fix it",
        title: "Fix",
        isolation: "project",
        callerAgentId: caller,
        project: harness.storedProjectId,
        sandboxProfile: "profile-1"
      })
    })

    expect(response.status).toBe(501)
  })
})
