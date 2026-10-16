import { createServer } from "node:http"

import {
  computerUseTools,
  textToolResult,
  type AutomationProviderContext
} from "@codevisor/automation"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import { CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js"
import { afterEach, describe, expect, it } from "vitest"

import { unavailableBrowserProvider } from "./mcp-automation-builtins.js"
import { executeTimeoutMessage, type ExecutionTimers } from "./mcp-gateway-execution.js"
import { cleanupMcpManagerTests, listen, run, testManager } from "./mcp-manager-test-support.js"
import { sdkTransport } from "./mcp-support.js"

afterEach(cleanupMcpManagerTests)

const manualTimers = () => {
  const scheduled: Array<{ readonly ms: number; readonly fire: () => void; cleared: boolean }> = []
  const timers: ExecutionTimers = {
    now: () => 1_000,
    setTimeout: (callback, ms) => {
      const entry = { ms, fire: callback, cleared: false }
      scheduled.push(entry)
      return () => {
        entry.cleared = true
      }
    }
  }
  return { scheduled, timers }
}

const deadlineGateway = async (timers: ExecutionTimers) => {
  const contexts: Array<AutomationProviderContext> = []
  let onInvoked: (() => void) | undefined
  const { db, manager } = await testManager({
    executionTimers: timers,
    makeBrowserProvider: () => unavailableBrowserProvider("Not used in this test"),
    makeComputerProvider: () => ({
      id: "computer",
      tools: computerUseTools,
      status: () => ({ available: true }),
      ensureSetup: async () => {},
      close: async () => {},
      closeSession: async () => {},
      invoke: async (context, toolName) => {
        contexts.push(context)
        if (toolName === "list_apps") return textToolResult(JSON.stringify({ apps: [] }))
        onInvoked?.()
        return new Promise((_, reject) =>
          context.signal?.addEventListener("abort", () => reject(context.signal?.reason), {
            once: true
          })
        )
      }
    })
  })
  manager.setBaseUrl(
    await listen(
      createServer((request, response) => manager.handleGatewayRequest(request, response))
    )
  )
  const project = await run(db.createProject({ folderPath: "/tmp/mcp-gateway-deadline" }))
  const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
  const issued = await manager.issueGateway(session.id, project.id, () => {})
  const client = new Client({ name: "deadline-test", version: "1" })
  await client.connect(
    sdkTransport(
      new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
      })
    )
  )
  const invoked = new Promise<void>((resolve) => (onInvoked = resolve))
  return { client, contexts, invoked }
}

describe("execute deadline", () => {
  it("stops the call at timeout_ms, cancels in-flight tools and names what was running", async () => {
    const { scheduled, timers } = manualTimers()
    const { client, contexts, invoked } = await deadlineGateway(timers)
    try {
      const pending = client.callTool({
        name: "execute",
        arguments: {
          description: "Read Music",
          code: 'async () => tools.computer.get_app_state({ app: "Music" })',
          timeout_ms: 5_000
        }
      })
      await invoked
      const deadline = scheduled.find((entry) => entry.ms === 5_000)!
      expect(contexts.at(-1)).toMatchObject({ deadline: 6_000 })
      expect(contexts.at(-1)?.signal?.aborted).toBe(false)
      deadline.fire()
      const result = CallToolResultSchema.parse(await pending)
      expect(result.isError).toBe(true)
      expect(result.content).toEqual([
        { type: "text", text: executeTimeoutMessage(5_000, ["computer.get_app_state"]) }
      ])
      expect(contexts.at(-1)?.signal?.aborted).toBe(true)
    } finally {
      await client.close()
    }
  })

  it("defaults to a two-minute deadline and clears it when the call finishes", async () => {
    const { scheduled, timers } = manualTimers()
    const { client } = await deadlineGateway(timers)
    try {
      const result = CallToolResultSchema.parse(
        await client.callTool({
          name: "execute",
          arguments: {
            description: "List apps",
            code: "async () => tools.computer.list_apps({})"
          }
        })
      )
      expect(result.isError).toBeUndefined()
      expect(scheduled.find((entry) => entry.ms === 120_000)?.cleared).toBe(true)
    } finally {
      await client.close()
    }
  })

  it("explains the timeout without saying a tool failed", () => {
    expect(executeTimeoutMessage(120_000, ["computer.js"])).toBe(
      "execute timed out after 120s (timeout_ms 120000) while computer.js was still running; its pending tool calls were cancelled. If this work legitimately needs longer, pass a larger timeout_ms (up to 600000)."
    )
    expect(executeTimeoutMessage(2_000, [])).toContain("while your code was running")
    expect(executeTimeoutMessage(2_000, ["computer.js", "browser.js", "computer.js"])).toContain(
      "while computer.js, browser.js were still running"
    )
  })
})
