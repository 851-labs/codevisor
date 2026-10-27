import { createHash } from "node:crypto"
import { mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { canonicalExecutionArgs } from "@codevisor/api"
import { makeBrowserUseProvider, textToolResult } from "@codevisor/automation"
import { afterEach, describe, expect, it } from "vitest"

import { unavailableBrowserProvider } from "./mcp-automation-builtins.js"
import {
  connectClient,
  listenWithMachines,
  studioGateway
} from "./mcp-gateway-machines-test-support.js"
import {
  cleanupMcpManagerTests,
  directories,
  executeResultValue,
  executionOf,
  run,
  testManager
} from "./mcp-manager-test-support.js"
import type { GatewayOrigin } from "./mcp-manager-types.js"

afterEach(cleanupMcpManagerTests)

const PNG_PIXEL =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

describe("gateway machines and execution annotations", () => {
  it("routes machine-targeted calls to the machine link and streams what ran to the session", async () => {
    const { db, manager, remoteCalls } = await studioGateway()
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-gateway-machines" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Ship it" })
    )
    const events: Array<RuntimeEvent> = []
    const issued = await manager.issueGateway(session.id, project.id, (event) => {
      events.push(event)
    })
    await manager.beginTurn(session.id, { clientId: "window-1" })
    const client = await connectClient(issued)
    try {
      const args = {
        description: "Build the app on the MacBook",
        code: `async () => {
          status("Finding the MacBook");
          const mbp = await machines.get("macbook");
          const built = await mbp.tools.xcode.build({ scheme: "App" });
          const lost = await mbp.tools.xcode.test({}).catch((error) => ({
            isClass: error instanceof MachineUnavailableError,
            name: error.name,
            phase: error.phase,
            machineName: error.machineName
          }));
          const context = await machines.current.tools.codevisor.context.current({});
          return { built, lost, context, bareTools: typeof tools };
        }`
      }
      const executed = await client.callTool({ name: "execute", arguments: args })

      expect(executed.isError).not.toBe(true)
      expect(executeResultValue(executed)).toEqual({
        built: { built: true },
        lost: {
          isClass: true,
          name: "MachineUnavailableError",
          phase: "in-flight",
          machineName: "MacBook Pro"
        },
        context: {
          agentId: session.id,
          projectId: project.id,
          machine: { machineId: "studio", name: "Mac Studio" },
          clientId: "window-1"
        },
        bareTools: "undefined"
      })
      const origin = {
        machineId: "studio",
        machineName: "Mac Studio",
        sessionId: session.id,
        sessionTitle: "Ship it",
        clientId: "window-1"
      }
      expect(remoteCalls).toEqual([
        { machine: "mbp", path: "xcode.build", args: { scheme: "App" }, origin },
        { machine: "mbp", path: "xcode.test", args: {}, origin }
      ])
      expect(JSON.stringify(executed.content)).not.toContain("codevisor_execution")

      const annotations = events.map((event) => {
        expect(event).toMatchObject({ kind: "session.output", subjectId: session.id })
        return event.payload
      })
      const argsHash = createHash("sha256").update(canonicalExecutionArgs(args)).digest("hex")
      expect(annotations[0]).toEqual({
        kind: "codevisor_execution",
        argsHash,
        execution: { state: "running", description: "Build the app on the MacBook", calls: [] }
      })
      expect(annotations.at(-1)).toEqual({
        kind: "codevisor_execution",
        argsHash,
        execution: {
          state: "completed",
          description: "Build the app on the MacBook",
          status: "Finding the MacBook",
          calls: [
            {
              path: "xcode.build",
              title: "Build",
              icon: { kind: "mcp", serverId: "xcode" },
              machine: "MacBook Pro",
              ok: true,
              ms: expect.any(Number)
            },
            {
              path: "xcode.test",
              title: "Test",
              icon: { kind: "mcp", serverId: "xcode" },
              machine: "MacBook Pro",
              ok: false,
              ms: expect.any(Number),
              error:
                "lost connection to MacBook Pro mid-call; the tool may or may not have completed"
            },
            {
              path: "codevisor.context.current",
              title: "Context current",
              icon: { kind: "builtin", id: "codevisor" },
              ok: true,
              ms: expect.any(Number)
            }
          ],
          icon: { kind: "mcp", serverId: "xcode" },
          activeIcon: { kind: "builtin", id: "codevisor" }
        }
      })

      const failed = await client.callTool({
        name: "execute",
        arguments: {
          description: "Check ".repeat(40),
          code: 'async () => { throw new Error("boom") }'
        }
      })
      expect(failed.isError).toBe(true)
      expect(executionOf(events.at(-1)!)).toEqual({
        state: "failed",
        description: `${"Check ".repeat(13)}C…`,
        calls: [],
        error: expect.stringContaining("boom")
      })

      const skillReports = async (skillArguments: Record<string, unknown>) => {
        await client.callTool({ name: "skills", arguments: skillArguments })
        return events.at(-1)!.payload
      }
      expect(await skillReports({ name: " execute " })).toEqual({
        kind: "codevisor_skill",
        skill: { name: "execute", ok: true }
      })
      expect(await skillReports({ name: "no-such-skill" })).toEqual({
        kind: "codevisor_skill",
        skill: { name: "no-such-skill", ok: false }
      })
      expect(await skillReports({})).toEqual({ kind: "codevisor_skill", skill: { ok: true } })
    } finally {
      await client.close()
    }
  })

  it("tells the other machine which bot the calling session works for", async () => {
    const { db, manager, remoteCalls } = await studioGateway()
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-gateway-bot-origin" }))
    const { session } = await run(
      db.createWorkspaceWithSession({
        workspace: {
          id: "a8a0d4f4-61c4-4a4e-8b1a-4f2f6e7c9b01",
          projectId: project.id,
          name: "Sub-agent",
          hasCustomName: false,
          botId: "0c6c4c55-0c0e-4b8e-9a53-2a1bb5d1f8d2",
          botMachineId: "machine-home"
        },
        session: { projectId: project.id, harnessId: "codex", title: "Sub-agent" }
      })
    )
    const client = await connectClient(await manager.issueGateway(session.id, project.id))
    try {
      await client.callTool({
        name: "execute",
        arguments: {
          description: "Start a helper on the MacBook",
          code: `async () => (await machines.get("mbp")).tools.codevisor.sessions.create({})`
        }
      })

      expect(remoteCalls.map((call) => call.origin)).toEqual([
        {
          machineId: "studio",
          machineName: "Mac Studio",
          sessionId: session.id,
          sessionTitle: "Sub-agent",
          botId: "0c6c4c55-0c0e-4b8e-9a53-2a1bb5d1f8d2",
          botMachineId: "machine-home"
        }
      ])
    } finally {
      await client.close()
    }
  })

  it("keeps sandbox code from sending machine-to-machine fleet messages", async () => {
    const { db, manager, remoteCalls } = await studioGateway()
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-gateway-fleet-path" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Sneaky" })
    )
    const client = await connectClient(await manager.issueGateway(session.id, project.id))
    try {
      const executed = await client.callTool({
        name: "execute",
        arguments: {
          description: "Forge an event",
          code: `async () => (await machines.get("mbp")).tools.fleet.session_event({ sessionId: "s" })`
        }
      })

      expect(executed.isError).toBe(true)
      expect(JSON.stringify(executed.content)).toContain("Unknown tool: fleet.session_event")
      expect(remoteCalls).toEqual([])
    } finally {
      await client.close()
    }
  })

  it("names a browser workflow after the site its tab reached", async () => {
    const root = await mkdtemp(join(tmpdir(), "gateway-browser-site-"))
    directories.push(root)
    const provider = makeBrowserUseProvider(root, "http://127.0.0.1:43210")
    const pages: Record<string, string | undefined> = {
      navigate: "https://linear.app/codevisor/issue/ABC-1",
      snapshot: "https://linear.app/codevisor/issue/ABC-2",
      tabs: undefined
    }
    const { db, manager } = await testManager({
      makeBrowserProvider: () => ({
        ...provider,
        invoke: async (_context, name) => {
          if (name === "screenshot") {
            return {
              content: [{ type: "image", mimeType: "image/png", data: PNG_PIXEL }]
            }
          }
          const url = pages[name]
          return textToolResult(url === undefined ? "{}" : `Page URL: ${url}\n{}`)
        }
      })
    })
    await listenWithMachines(manager)
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-gateway-site" }))
    const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
    const events: Array<RuntimeEvent> = []
    const issued = await manager.issueGateway(session.id, project.id, (event) => {
      events.push(event)
    })
    const client = await connectClient(issued)
    try {
      const executed = await client.callTool({
        name: "execute",
        arguments: {
          description: "Read the Linear issue",
          code: `async () => {
            await machines.current.tools.browser.navigate({ url: "https://linear.app/codevisor/issue/ABC-1" });
            await machines.current.tools.browser.snapshot({});
            await machines.current.tools.browser.screenshot({});
            await machines.current.tools.browser.tabs({ action: "list" });
            return true;
          }`
        }
      })
      expect(executed.isError, JSON.stringify(executed)).not.toBe(true)
      const site = { kind: "site", origin: "https://linear.app" }
      expect(executionOf(events.at(-1)!)).toMatchObject({
        state: "completed",
        icon: site,
        activeIcon: site,
        calls: [
          { title: "Navigate", icon: site },
          { title: "Snapshot", icon: site },
          {
            title: "Screenshot",
            icon: site,
            files: [
              { fileId: expect.any(String), name: "browser-screenshot.png", mimeType: "image/png" }
            ]
          },
          { title: "Tabs", icon: site }
        ]
      })
    } finally {
      await client.close()
      await provider.close()
    }
  })

  it("closes the tabs a turn opened on another machine's browser when the turn ends", async () => {
    const { db, manager, remoteCalls } = await studioGateway()
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-remote-browser" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Browse" })
    )
    const issued = await manager.issueGateway(session.id, project.id)
    await manager.beginTurn(session.id)
    const client = await connectClient(issued)
    try {
      const executed = await client.callTool({
        name: "execute",
        arguments: {
          description: "Open a page on the MacBook",
          code: `async () => {
            const mbp = await machines.get("macbook");
            await mbp.tools.browser.tabs({ action: "new" });
            return true;
          }`
        }
      })
      expect(executed.isError).not.toBe(true)
      remoteCalls.length = 0

      await manager.finishTurn(session.id)
      expect(remoteCalls).toEqual([
        expect.objectContaining({
          machine: "mbp",
          path: "browser.finalizeTabs",
          args: { native: true },
          origin: expect.objectContaining({ sessionId: session.id })
        })
      ])
      await manager.finishTurn(session.id)
      await manager.closeSession(session.id)
      expect(remoteCalls).toHaveLength(1)
    } finally {
      await client.close()
    }
  })

  it("fails machine-targeted calls as unavailable when the server has no machine link", async () => {
    const { db, manager } = await testManager({
      machine: { id: "studio", name: "Mac Studio" },
      makeBrowserProvider: () => unavailableBrowserProvider("Not used in this test")
    })
    await listenWithMachines(manager)
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-gateway-offline" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Offline" })
    )
    const client = await connectClient(await manager.issueGateway(session.id))
    try {
      const executed = await client.callTool({
        name: "execute",
        arguments: {
          description: "Build on the MacBook",
          code: `async () => {
            const mbp = await machines.get("mbp");
            return mbp.tools.xcode.build({}).catch((error) => ({
              isClass: error instanceof MachineUnavailableError,
              machineId: error.machineId,
              phase: error.phase
            }));
          }`
        }
      })
      expect(executeResultValue(executed)).toEqual({
        isClass: true,
        machineId: "mbp",
        phase: "before-send"
      })
    } finally {
      await client.close()
    }
  })

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

  it("runs calls from another machine under a scoped session labelled with the caller", async () => {
    const { computerContexts, manager } = await studioGateway()
    const origin: GatewayOrigin = {
      machineId: "mbp",
      machineName: "MacBook Pro",
      sessionId: "chat-7",
      sessionTitle: "Fix the build"
    }

    expect(await manager.invokeRemoteGatewayCall(origin, "computer.list_apps", {})).toEqual({
      apps: []
    })
    expect(computerContexts.at(-1)).toMatchObject({
      sessionId: "remote2:mbp:chat-7",
      agentLabel: "Fix the build (from MacBook Pro)"
    })
    expect(await manager.invokeRemoteGatewayCall(origin, "codevisor.context.current", {})).toEqual({
      agentId: "remote2:mbp:chat-7",
      machine: { machineId: "studio", name: "Mac Studio" }
    })
  })
})
