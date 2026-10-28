import { afterEach, describe, expect, it } from "vitest"

import { withCallerDefaults } from "./mcp-gateway-agent-start.js"
import { connectClient, studioGateway } from "./mcp-gateway-machines-test-support.js"
import { cleanupMcpManagerTests, run } from "./mcp-manager-test-support.js"

afterEach(cleanupMcpManagerTests)

describe("agents.start on another machine", () => {
  it("starts an agent on another machine with the caller's harness, picks and running effort", async () => {
    const { db, manager, remoteCalls } = await studioGateway()
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-gateway-remote-start" }))
    const session = await run(
      db.createSession({
        harnessId: "codex",
        projectId: project.id,
        title: "Plan it",
        configSelections: { model: "gpt-6" }
      })
    )
    await run(
      db.saveSessionRuntimeState(session.id, {
        configOptions: [
          {
            category: "thought_level",
            currentValue: "high",
            id: "reasoning",
            name: "Reasoning",
            options: [{ name: "High", value: "high" }]
          }
        ]
      })
    )
    const issued = await manager.issueGateway(session.id, project.id)
    const client = await connectClient(issued)
    try {
      const start = {
        title: "Build it",
        prompt: "Build the app",
        isolation: "worktree",
        project: "app"
      }
      await client.callTool({
        name: "execute",
        arguments: {
          description: "Start an agent on the MacBook",
          code: `async () => (await machines.get("macbook")).agents.start(${JSON.stringify(start)})`
        }
      })

      expect(remoteCalls.map(({ path, args }) => ({ path, args }))).toEqual([
        {
          path: "codevisor.agents.start",
          args: {
            ...start,
            callerDefaults: {
              harness: "codex",
              configSelections: { model: "gpt-6", reasoning: "high" }
            }
          }
        }
      ])
    } finally {
      await client.close()
    }
  })

  it("tells the other machine which repository to clone when it lacks the caller's project", async () => {
    const { db, manager, remoteCalls } = await studioGateway()
    const project = await run(
      db.createProject({
        folderPath: "/tmp/mcp-gateway-remote-clone",
        name: "widget",
        repoUrl: "https://github.com/acme/widget.git"
      })
    )
    const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
    const issued = await manager.issueGateway(session.id, project.id)
    const client = await connectClient(issued)
    try {
      const start = { title: "Build it", prompt: "Build the app", isolation: "worktree" }
      await client.callTool({
        name: "execute",
        arguments: {
          description: "Start an agent on the MacBook",
          code: `async () => (await machines.get("macbook")).agents.start(${JSON.stringify(start)})`
        }
      })

      expect(remoteCalls.at(-1)?.args).toEqual({
        ...start,
        callerDefaults: {
          harness: "codex",
          project: { name: "widget", repoUrl: "https://github.com/acme/widget.git" }
        }
      })
    } finally {
      await client.close()
    }
  })

  it("forwards the arguments untouched when the calling chat no longer exists", async () => {
    const { db } = await studioGateway()
    const args = { title: "Build it", prompt: "Build the app", isolation: "worktree" }

    expect(await withCallerDefaults(db, "gone", "codevisor.agents.start", args)).toBe(args)
  })
})
