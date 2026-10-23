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
import type { ExecutionTimers } from "./mcp-gateway-execution.js"
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
  let release: ((text: string) => void) | undefined
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
        return new Promise((resolve, reject) => {
          release = (text) => resolve(textToolResult(text))
          context.signal?.addEventListener("abort", () => reject(context.signal?.reason), {
            once: true
          })
        })
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
  return { client, contexts, invoked, manager, release: (text: string) => release?.(text) }
}

describe("execute deadline", () => {
  it("returns a still-running handle at timeout_ms and lets the in-flight tool finish as a job", async () => {
    const { scheduled, timers } = manualTimers()
    const { client, contexts, invoked, manager, release } = await deadlineGateway(timers)
    try {
      const pending = client.callTool({
        name: "execute",
        arguments: {
          description: "Read Music",
          code: 'async () => machines.current.tools.computer.get_app_state({ app: "Music" })',
          timeout_ms: 5_000
        }
      })
      await invoked
      expect(contexts.at(-1)).toMatchObject({ deadline: 6_000 })
      scheduled.find((entry) => entry.ms === 5_000)!.fire()
      const result = CallToolResultSchema.parse(await pending)
      const block = result.content[0]
      const handle = JSON.parse(block?.type === "text" ? block.text : "{}")

      expect(result.isError).toBeUndefined()
      expect(handle).toMatchObject({ status: "running", running: ["computer.get_app_state"] })
      expect(contexts.at(-1)?.signal?.aborted).toBe(false)
      expect(manager.jobs.get(handle.jobId)).toMatchObject({ state: "running" })

      release(JSON.stringify({ app: "Music" }))
      const finished = await manager.jobs.wait(handle.jobId, 60_000)
      expect(finished).toMatchObject({
        timedOut: false,
        job: { state: "completed", result: { app: "Music" }, running: [] }
      })
    } finally {
      await client.close()
    }
  })

  it("defaults to a two-minute budget and keeps quick calls inline", async () => {
    const { scheduled, timers } = manualTimers()
    const { client } = await deadlineGateway(timers)
    try {
      const result = CallToolResultSchema.parse(
        await client.callTool({
          name: "execute",
          arguments: {
            description: "List apps",
            code: "async () => machines.current.tools.computer.list_apps({})"
          }
        })
      )
      expect(result.isError).toBeUndefined()
      expect(scheduled.find((entry) => entry.ms === 120_000)?.cleared).toBe(true)
    } finally {
      await client.close()
    }
  })
})
