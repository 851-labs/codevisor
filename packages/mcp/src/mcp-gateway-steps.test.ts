import type { RuntimeEvent } from "@codevisor/agent-runtime"
import type { CodevisorExecutionState } from "@codevisor/api"
import type { McpServerRecord } from "@codevisor/db"
import { describe, expect, it } from "vitest"

import { makeExecutionRecorder } from "./mcp-gateway-execution.js"
import { makeExecutionSteps } from "./mcp-gateway-steps.js"
import type { SandboxArtifactCollector } from "./mcp-sandbox-results.js"
import type { UpstreamConnection } from "./mcp-support.js"

const harness = (stored: ReadonlyArray<string | undefined>) => {
  const events: Array<RuntimeEvent> = []
  const recorder = makeExecutionRecorder({
    sink: (event) => void events.push(event),
    sessionId: "s",
    argsHash: "h"
  })
  const queue = [...stored]
  const collector: SandboxArtifactCollector = {
    content: [],
    maxItems: 4,
    maxBytes: 1_000,
    persistence: {
      // Each stored artifact gets the next queued id; undefined means it wasn't kept.
      persist: async () => {
        const id = queue.shift()
        return id === undefined
          ? undefined
          : {
              fileId: id,
              name: `${id}.png`,
              mimeType: "image/png",
              sizeBytes: 1,
              kind: "image",
              path: "/x"
            }
      }
    }
  }
  const servers: Record<string, Partial<McpServerRecord>> = {
    remote: { url: "https://mcp.linear.app/mcp" },
    local: {}
  }
  const steps = makeExecutionSteps({
    recorder,
    collector,
    record: async (id) => {
      if (servers[id] === undefined) throw new Error("missing")
      return servers[id] as McpServerRecord
    },
    automationProviders: new Map(),
    connectUpstream: async (id) => {
      if (id !== "remote") throw new Error("not connected")
      return {
        tools: [{ name: "list_issues", title: "List issues", inputSchema: { type: "object" } }]
      } as unknown as UpstreamConnection
    }
  })
  const finished = async () => {
    await recorder.finish()
    return (events.at(-1)!.payload as { execution: CodevisorExecutionState }).execution
  }
  return { steps, finished }
}

describe("execution steps", () => {
  it("labels each settled call and gives it the files it stored", async () => {
    const { steps, finished } = harness(["shot-1", undefined])
    const persist = steps.artifacts.persistence!.persist
    const artifact = {
      data: Buffer.from(""),
      mimeType: "image/png",
      toolPath: "browser.screenshot"
    }

    const remote = await steps.begin("remote.list_issues", { internal: false, local: true })
    await persist(artifact)
    await persist(artifact)
    await remote({ ok: true, value: { files: [{ fileId: "shot-1" }, { fileId: "export-2" }] } })

    const local = await steps.begin("local.run", { internal: false, local: true })
    await local({ ok: false, error: "Error: boom" })

    const elsewhere = await steps.begin("remote.list_issues", {
      internal: false,
      local: false,
      machine: "MacBook Pro"
    })
    await elsewhere({ ok: true, value: null })

    const prelude = await steps.begin("search", { internal: true, local: true })
    await prelude({ ok: true, value: {} })

    // Pages that aren't sites leave the browser's icon alone.
    steps.onBrowserPage("about:blank")

    expect((await finished()).calls).toEqual([
      {
        path: "remote.list_issues",
        title: "List issues",
        icon: { kind: "mcp", serverId: "remote", host: "mcp.linear.app" },
        ok: true,
        ms: expect.any(Number),
        files: [
          { fileId: "shot-1", name: "shot-1.png", mimeType: "image/png" },
          { fileId: "export-2" }
        ]
      },
      {
        path: "local.run",
        title: "Run",
        icon: { kind: "mcp", serverId: "local" },
        ok: false,
        ms: expect.any(Number),
        error: "boom"
      },
      {
        path: "remote.list_issues",
        title: "List issues",
        icon: { kind: "mcp", serverId: "remote", host: "mcp.linear.app" },
        machine: "MacBook Pro",
        ok: true,
        ms: expect.any(Number)
      }
    ])
  })
})
