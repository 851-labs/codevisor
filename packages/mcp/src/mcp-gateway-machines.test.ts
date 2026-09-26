import { createHash } from "node:crypto"
import { createServer } from "node:http"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { canonicalExecutionArgs } from "@codevisor/api"
import {
  CodeExecutionToolError,
  computerUseTools,
  textToolResult,
  type AutomationProviderContext
} from "@codevisor/automation"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { afterEach, describe, expect, it } from "vitest"

import { unavailableBrowserProvider } from "./mcp-automation-builtins.js"
import { CODEVISOR_AGENT_INSTRUCTIONS } from "./mcp-gateway-catalog.js"
import { cleanupMcpManagerTests, listen, run, testManager } from "./mcp-manager-test-support.js"
import type { GatewayOrigin, McpManager } from "./mcp-manager-types.js"

afterEach(cleanupMcpManagerTests)

const machineRoster = {
  machines: [
    { id: "studio", name: "Mac Studio", online: true, isCurrent: true },
    { id: "mbp", name: "MacBook Pro", online: true, isCurrent: false }
  ]
}

/// Serves the gateway plus GET /v1/machines (the codevisor.machines.list route).
const listenWithMachines = async (manager: McpManager): Promise<void> => {
  manager.setBaseUrl(
    await listen(
      createServer((request, response) => {
        if (request.url === "/v1/machines") {
          response.writeHead(200, { "content-type": "application/json" })
          response.end(JSON.stringify(machineRoster))
          return
        }
        void manager.handleGatewayRequest(request, response)
      })
    )
  )
}

/// A manager on "Mac Studio" whose machine link is a fake.
const studioGateway = async () => {
  const remoteCalls: Array<{
    machine: string
    path: string
    args: unknown
    origin: GatewayOrigin
  }> = []
  const computerContexts: Array<AutomationProviderContext> = []
  const { db, manager } = await testManager(undefined, {
    machine: { id: "studio", name: "Mac Studio" },
    makeBrowserProvider: () => unavailableBrowserProvider("Not used in this test"),
    makeComputerProvider: () => ({
      id: "computer",
      tools: computerUseTools,
      status: () => ({ available: true }),
      ensureSetup: async () => {},
      close: async () => {},
      closeSession: async () => {},
      invoke: async (context) => {
        computerContexts.push(context)
        return textToolResult(JSON.stringify({ apps: [] }))
      }
    }),
    remoteInvoker: async (machine, path, args, origin) => {
      remoteCalls.push({ machine, path, args, origin })
      if (path === "xcode.test") {
        throw new CodeExecutionToolError(
          "lost connection to MacBook Pro mid-call; the tool may or may not have completed",
          {
            code: "machine_unavailable",
            details: { machineId: "mbp", name: "MacBook Pro", phase: "in-flight" }
          }
        )
      }
      return { built: true }
    }
  })
  await listenWithMachines(manager)
  return { computerContexts, db, manager, remoteCalls }
}

const connectClient = async (issued: { url: string; bearerToken: string }) => {
  const client = new Client({ name: "machines-test", version: "1" })
  await client.connect(
    new StreamableHTTPClientTransport(new URL(issued.url), {
      requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
    }) as unknown as Transport
  )
  return client
}

const resultValue = (content: unknown): unknown => {
  const text = (content as Array<{ type: string; text?: string }>).find(
    (block) => block.type === "text"
  )?.text
  return (JSON.parse(text!) as { result: unknown }).result
}

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
    // Every agent learns when to delegate to Codevisor agents.
    expect(issued.instructions).toBe(CODEVISOR_AGENT_INSTRUCTIONS)
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
          const context = await tools.codevisor.context.current({});
          return { built, lost, context, currentIsTools: machines.current.tools === tools };
        }`
      }
      const executed = await client.callTool({ name: "execute", arguments: args })

      expect(executed.isError).not.toBe(true)
      expect(resultValue(executed.content)).toEqual({
        built: { built: true },
        lost: {
          isClass: true,
          name: "MachineUnavailableError",
          phase: "in-flight",
          machineName: "MacBook Pro"
        },
        context: {
          sessionId: session.id,
          projectId: project.id,
          machine: { id: "studio", name: "Mac Studio" },
          clientId: "window-1"
        },
        currentIsTools: true
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
      // The call record is transcript-only; the model sees just its result.
      expect(JSON.stringify(executed.content)).not.toContain("codevisor_execution")

      const annotations = events.map((event) => {
        expect(event).toMatchObject({ kind: "session.output", subjectId: session.id })
        return event.payload as { kind: string; argsHash: string; execution: unknown }
      })
      const argsHash = createHash("sha256").update(canonicalExecutionArgs(args)).digest("hex")
      expect(annotations[0]).toEqual({
        kind: "codevisor_execution",
        argsHash,
        execution: { state: "running", calls: [] }
      })
      expect(annotations.at(-1)).toEqual({
        kind: "codevisor_execution",
        argsHash,
        execution: {
          state: "completed",
          status: "Finding the MacBook",
          // machines.get's own lookup is the prelude's, not the script's.
          calls: [
            { path: "xcode.build", machine: "MacBook Pro", ok: true, ms: expect.any(Number) },
            {
              path: "xcode.test",
              machine: "MacBook Pro",
              ok: false,
              ms: expect.any(Number),
              error:
                "lost connection to MacBook Pro mid-call; the tool may or may not have completed"
            },
            { path: "codevisor.context.current", ok: true, ms: expect.any(Number) }
          ]
        }
      })

      // A long label is accepted as-is; a failing script ends "failed".
      const failed = await client.callTool({
        name: "execute",
        arguments: {
          description: "Check ".repeat(40),
          code: 'async () => { throw new Error("boom") }'
        }
      })
      expect(failed.isError).toBe(true)
      expect((events.at(-1)!.payload as { execution: unknown }).execution).toEqual({
        state: "failed",
        calls: [],
        error: expect.stringContaining("boom")
      })
    } finally {
      await client.close()
    }
  })

  it("fails machine-targeted calls as unavailable when the server has no machine link", async () => {
    const { db, manager } = await testManager(undefined, {
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
      expect(resultValue(executed.content)).toEqual({
        isClass: true,
        machineId: "mbp",
        phase: "before-send"
      })
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
      sessionId: "remote:mbp:chat-7",
      agentLabel: "Fix the build (from MacBook Pro)"
    })
    expect(await manager.invokeRemoteGatewayCall(origin, "codevisor.context.current", {})).toEqual({
      sessionId: "remote:mbp:chat-7",
      machine: { id: "studio", name: "Mac Studio" }
    })
    await expect(
      manager.invokeRemoteGatewayCall(origin, "plugin.owner.notes.notes_add", {})
    ).rejects.toThrow(
      "plugin.owner.notes.notes_add failed without a workspace folder (called from MacBook Pro)"
    )
  })
})
