import { createServer } from "node:http"

import {
  CodeExecutionToolError,
  computerUseTools,
  textToolResult,
  type AutomationProviderContext
} from "@codevisor/automation"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"

import { unavailableBrowserProvider } from "./mcp-automation-builtins.js"
import { listen, testManager } from "./mcp-manager-test-support.js"
import type { GatewayOrigin, McpManager } from "./mcp-manager-types.js"
import { sdkTransport } from "./mcp-support.js"

const machineRoster = {
  machines: [
    { id: "studio", name: "Mac Studio", online: true, isCurrent: true },
    { id: "mbp", name: "MacBook Pro", online: true, isCurrent: false }
  ]
}

export const listenWithMachines = async (manager: McpManager): Promise<void> => {
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

export const studioGateway = async () => {
  const remoteCalls: Array<{
    machine: string
    path: string
    args: unknown
    origin: GatewayOrigin
  }> = []
  const computerContexts: Array<AutomationProviderContext> = []
  const { db, manager } = await testManager({
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

export const connectClient = async (issued: { url: string; bearerToken: string }) => {
  const client = new Client({ name: "machines-test", version: "1" })
  await client.connect(
    sdkTransport(
      new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
      })
    )
  )
  return client
}
