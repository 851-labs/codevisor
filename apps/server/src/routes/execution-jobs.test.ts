import { mkdirSync, mkdtempSync, realpathSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import {
  decode,
  ExecutionJob,
  ExecutionJobList,
  SessionSummary,
  TranscriptPage
} from "@codevisor/api"
import type { ExecutionTimers } from "@codevisor/mcp"
import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js"
import { CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js"
import { describe, expect, it, onTestFinished } from "vitest"

import { jsonRequest, observableFixture, start, tempDirs, waitFor } from "../test-support.js"
import { git } from "./bot-test-support.js"
import { gatewayTransport } from "./gateway-test-support.js"

const yieldTimers = () => {
  const scheduled: Array<{ readonly ms: number; readonly fire: () => void }> = observableFixture([])
  const timers: ExecutionTimers = {
    now: () => performance.now(),
    setTimeout: (callback, ms) => {
      const entry = { ms, fire: callback }
      scheduled.push(entry)
      return () => scheduled.splice(scheduled.indexOf(entry), 1)
    }
  }
  return {
    timers,
    scheduled: (ms: number) => scheduled.some((entry) => entry.ms === ms),
    fire: (ms: number) => scheduled.find((entry) => entry.ms === ms)!.fire()
  }
}

const BUDGET_MS = 600_000

const fixture = async () => {
  const clock = yieldTimers()
  const running = await start(undefined, { executionTimers: clock.timers })
  const folder = realpathSync(mkdtempSync(join(tmpdir(), "codevisor-jobs-project-")))
  tempDirs.push(folder)
  mkdirSync(join(folder, "repo"))
  await git(["init", "-b", "main"], join(folder, "repo"))
  await post(running, "/v1/projects", { folderPath: join(folder, "repo"), id: "jobs-project" })
  return { ...running, clock }
}

type Running = Awaited<ReturnType<typeof fixture>>

const post = (running: Pick<Running, "server">, path: string, body: Record<string, unknown>) =>
  jsonRequest(running.server, path, { body: JSON.stringify(body), method: "POST" })

const createChat = async (running: Running, title: string) =>
  decode(SessionSummary)(
    (await post(running, "/v1/sessions", { projectId: "jobs-project", harnessId: "codex", title }))
      .body
  ).id

const keepBusy = async (running: Running, sessionId: string) => {
  const before = running.agents.prompts.length
  await post(running, `/v1/sessions/${sessionId}/prompt`, { text: "prompt until cancelled" })
  await waitFor(() => running.agents.prompts.length > before)
}

const gatewayClient = async (running: Running, sessionId: string) => {
  const reported: Array<RuntimeEvent> = observableFixture([])
  const gateway = await running.services.mcp.issueGateway(sessionId, "jobs-project", (event) => {
    reported.push(event)
  })
  const client = new McpClient({ name: "jobs-test", version: "1" })
  await client.connect(gatewayTransport(gateway))
  onTestFinished(() => client.close())
  const toolStarted = () =>
    reported.some((event) =>
      JSON.stringify(event.payload).includes('"activeIcon":{"kind":"builtin"')
    )
  return { client, toolStarted }
}

const waitOnChild = ({ client }: { readonly client: McpClient }, childId: string) =>
  client.callTool({
    name: "execute",
    arguments: {
      description: "Wait for the helper",
      code: `async () => machines.current.agents.wait({ agentIds: ["${childId}"], until: ["idle"], timeoutMs: 300000 })`,
      timeout_ms: BUDGET_MS
    }
  })

const detachedHandle = async (
  running: Running,
  gateway: Awaited<ReturnType<typeof gatewayClient>>,
  pending: ReturnType<typeof waitOnChild>
) => {
  await waitFor(() => gateway.toolStarted() && running.clock.scheduled(BUDGET_MS))
  running.clock.fire(BUDGET_MS)
  const result = CallToolResultSchema.parse(await pending)
  const block = result.content[0]
  return { result, handle: JSON.parse(block?.type === "text" ? block.text : "{}") }
}

const hiddenEvents = async (running: Running, sessionId: string) =>
  decode(TranscriptPage)(
    (await jsonRequest(running.server, `/v1/sessions/${sessionId}/transcript`)).body
  ).items.flatMap((item) => (item.origin === "event" ? [item.text] : []))

describe("background execute jobs", () => {
  it("hands back a still-running handle, then wakes the caller with the job's result", async () => {
    const running = await fixture()
    const parent = await createChat(running, "Lead")
    const child = await createChat(running, "Slow helper")
    await keepBusy(running, child)
    const gateway = await gatewayClient(running, parent)

    const { result, handle } = await detachedHandle(running, gateway, waitOnChild(gateway, child))
    await post(running, `/v1/sessions/${child}/cancel`, {})
    await waitFor(async () => (await hiddenEvents(running, parent)).length === 1)

    expect(result.isError).toBeUndefined()
    expect(handle).toMatchObject({ status: "running", running: ["codevisor.agents.wait"] })
    const [event] = await hiddenEvents(running, parent)
    expect(event).toContain(
      `<codevisor-event type="execution.job_finished" jobId="${handle.jobId}" agentId="${parent}" state="completed" description="Wait for the helper">`
    )
    expect(event).toContain(`Result: {"items":[{"agentId":"${child}","state":"idle"}]`)
    expect(event).toContain(`"timedOut":false}`)
    expect(event).toContain(`Full output: ${handle.outputPath}`)
  })

  it("cancels a deleted session's running jobs", async () => {
    const running = await fixture()
    const parent = await createChat(running, "Lead")
    const child = await createChat(running, "Slow helper")
    await keepBusy(running, child)
    const gateway = await gatewayClient(running, parent)
    const { handle } = await detachedHandle(running, gateway, waitOnChild(gateway, child))
    const finished = new Promise<void>((resolve) =>
      running.services.mcp.jobs.subscribe(() => resolve())
    )

    await jsonRequest(running.server, `/v1/sessions/${parent}`, { method: "DELETE" })
    await finished

    expect((await jsonRequest(running.server, `/v1/jobs/${handle.jobId}`)).body).toMatchObject({
      state: "cancelled"
    })
    await post(running, `/v1/sessions/${child}/cancel`, {})
  })

  it("lets the caller list, poll, and cancel a job over the API", async () => {
    const running = await fixture()
    const parent = await createChat(running, "Lead")
    const child = await createChat(running, "Slow helper")
    await keepBusy(running, child)
    const gateway = await gatewayClient(running, parent)
    const { handle } = await detachedHandle(running, gateway, waitOnChild(gateway, child))

    const listed = decode(ExecutionJobList)(
      (await jsonRequest(running.server, `/v1/sessions/${parent}/jobs`)).body
    )
    const polling = post(running, `/v1/jobs/${handle.jobId}/wait`, { timeoutMs: 1_000 })
    await waitFor(() => running.clock.scheduled(1_000))
    running.clock.fire(1_000)
    const polled = await polling
    const cancelled = decode(ExecutionJob)(
      (await post(running, `/v1/jobs/${handle.jobId}/cancel`, {})).body
    )
    const fetched = decode(ExecutionJob)(
      (await jsonRequest(running.server, `/v1/jobs/${handle.jobId}`)).body
    )
    const unknownWait = await post(running, "/v1/jobs/feedface01/wait", {})
    const unknownCancel = await post(running, "/v1/jobs/feedface01/cancel", {})

    expect(listed.jobs).toEqual([
      expect.objectContaining({ jobId: handle.jobId, state: "running" })
    ])
    expect(polled.body).toMatchObject({ timedOut: true, job: { state: "running" } })
    expect(cancelled.state).toBe("cancelled")
    expect(fetched.state).toBe("cancelled")
    expect([unknownWait.status, unknownCancel.status]).toEqual([404, 404])
    await post(running, `/v1/sessions/${child}/cancel`, {})
  })
})
