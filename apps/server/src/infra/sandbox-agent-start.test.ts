import { describe, expect, it } from "vitest"

import { HttpFailure } from "../server-context.js"
import {
  JOINED_DEVICE,
  JOINED_SERVER,
  readyHarness,
  sandboxHarness
} from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Spike box" }

const agent = {
  prompt: "Fix the flaky test",
  title: "Fix flake",
  harness: "codex",
  model: "gpt-6",
  labels: { issue: "851-1" },
  parentSessionId: "caller-session"
}

describe("starting an agent on a new sandbox", () => {
  it("starts it for its caller once the harness is ready, in a workspace of its own", async () => {
    const harness = await sandboxHarness({ onCurl: readyHarness("codex") })

    await harness.machines.create({ ...request, agent })
    await harness.machines.settled()

    const [machine] = await harness.machines.list()
    expect(machine).toMatchObject({
      state: "ready",
      harnessId: "codex",
      defersWorkspace: true,
      agent,
      agentId: "remote-agent",
      workspaceId: "remote-ws",
      workspaceOpenedAt: "2026-10-23T00:00:00.000Z"
    })
    expect(harness.toolCalls.map((call) => call.tool)).toEqual([
      "codevisor.projects.clone",
      "codevisor.agents.start"
    ])
    expect(harness.toolCalls[1]).toEqual({
      machineId: JOINED_SERVER,
      tool: "codevisor.agents.start",
      args: {
        prompt: "Fix the flaky test",
        title: "Fix flake",
        isolation: "project",
        harness: "codex",
        project: "remote-project",
        model: "gpt-6",
        labels: { issue: "851-1" }
      },
      sessionId: "caller-session"
    })
    expect((await harness.machines.log("id-1")).map((log) => log.line)).toEqual(
      expect.arrayContaining([
        "Waiting for codex to be ready on Spike box",
        "Started Fix flake on Spike box"
      ])
    )
  })

  it("starts an agent with no caller, model or labels as a plain chat", async () => {
    const harness = await sandboxHarness({ onCurl: readyHarness("codex") })

    await harness.machines.create({
      ...request,
      agent: { prompt: "Look around", title: "Explore", harness: "codex" }
    })
    await harness.machines.settled()

    expect(harness.toolCalls[1]).toEqual({
      machineId: JOINED_SERVER,
      tool: "codevisor.agents.start",
      args: {
        prompt: "Look around",
        title: "Explore",
        isolation: "project",
        harness: "codex",
        project: "remote-project"
      }
    })
  })

  it.each([["started"], [42], [{ agentId: "remote-agent" }]])(
    "fails and tears the sandbox down when it answers %j instead of the agent it started",
    async (answer) => {
      const harness = await sandboxHarness({ onCurl: readyHarness("codex") })
      harness.controls.answer = (tool) => (tool === "codevisor.agents.start" ? answer : undefined)

      await harness.machines.create({ ...request, agent })
      await harness.machines.settled()

      expect(await harness.machines.get("id-1")).toMatchObject({
        state: "failed",
        error: "The sandbox didn't say which agent it started"
      })
      expect(harness.removed).toEqual([JOINED_DEVICE])
    }
  )

  it("refuses an agent for a workspace the request names, since the agent starts in its own", async () => {
    const harness = await sandboxHarness({ onCurl: readyHarness("codex") })

    const refused = harness.machines.create({ ...request, workspaceId: "chat-ws", agent })

    await expect(refused).rejects.toEqual(
      new HttpFailure(
        400,
        "Pass workspaceId or agent, not both: the agent starts in a new workspace of its own"
      )
    )
    expect(await harness.machines.list()).toEqual([])
    expect(harness.provider.machines.size).toBe(0)
  })
})
