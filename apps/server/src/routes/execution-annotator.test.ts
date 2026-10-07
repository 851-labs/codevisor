import { createHash } from "node:crypto"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import {
  canonicalExecutionArgs,
  type CodevisorExecutionState,
  type EventEnvelope
} from "@codevisor/api"
import { describe, expect, it } from "vitest"

import type { CodevisorServerServices } from "../server-context.js"
import { makeEventFanout } from "../server.js"
import { makeServices, run, tempDirs } from "../test-support.js"
import { ExecutionAnnotator } from "./execution-annotator.js"
import { sessionEventSink } from "./session-events.js"

const args = { description: "List open Linear issues", code: "async () => tools.linear.list()" }
// The gateway hashes the arguments exactly as it received them.
const argsHash = (input: unknown) =>
  createHash("sha256").update(canonicalExecutionArgs(input)).digest("hex")

const running: CodevisorExecutionState = { state: "running", status: "Listing issues", calls: [] }
const completed: CodevisorExecutionState = {
  state: "completed",
  calls: [{ path: "linear.list_issues", ok: true, ms: 12 }]
}

const output = (payload: Record<string, unknown>): RuntimeEvent => ({
  kind: "session.output",
  subjectId: "subject",
  payload
})
const gateway = (execution: CodevisorExecutionState, input: unknown = args) =>
  output({ kind: "codevisor_execution", argsHash: argsHash(input), execution })
const payloads = (events: ReadonlyArray<RuntimeEvent>) => events.map((event) => event.payload)

const fixture = () => {
  let now = 0
  const annotator = new ExecutionAnnotator(() => now)
  return {
    annotator,
    advance: (ms: number) => {
      now += ms
    },
    annotate: (event: RuntimeEvent) => annotator.annotate("session", event)
  }
}

describe("ExecutionAnnotator", () => {
  it("attaches gateway state to the Codex row that carried the same arguments", () => {
    const f = fixture()
    const call = output({
      sessionUpdate: "tool_call",
      toolCallId: "call-1",
      title: "codevisor.execute",
      status: "in_progress",
      parentToolCallId: "task-1",
      rawInput: args
    })
    expect(f.annotate(call)).toEqual([call])
    expect(payloads(f.annotate(gateway(running)))).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "call-1",
        parentToolCallId: "task-1",
        _meta: { codevisorExecution: running }
      }
    ])
  })

  it("recognizes Grok's spelling of the gateway tool", () => {
    const f = fixture()
    const call = output({
      sessionUpdate: "tool_call",
      toolCallId: "grok-1",
      title: "codevisor__execute",
      status: "in_progress",
      rawInput: args
    })
    expect(f.annotate(call)).toEqual([call])
    expect(payloads(f.annotate(gateway(running)))).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "grok-1",
        _meta: { codevisorExecution: running }
      }
    ])
  })

  it("holds the latest early gateway state until Claude reports the arguments", () => {
    const f = fixture()
    f.annotate(
      output({
        sessionUpdate: "tool_call",
        toolCallId: "call-1",
        title: "mcp__codevisor__execute",
        status: "in_progress"
      })
    )
    expect(f.annotate(gateway(running))).toEqual([])
    expect(f.annotate(gateway(completed))).toEqual([])
    const update = output({
      sessionUpdate: "tool_call_update",
      toolCallId: "call-1",
      status: "in_progress",
      rawInput: args
    })
    const events = f.annotate(update)
    expect(events[0]).toBe(update)
    expect(payloads(events.slice(1))).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "call-1",
        _meta: { codevisorExecution: completed }
      }
    ])
    // The buffered state was consumed, and repeats of the same input are inert.
    expect(f.annotate(update)).toEqual([update])
  })

  it("drops gateway state that never correlates within the buffer window", () => {
    const f = fixture()
    expect(f.annotate(gateway(running))).toEqual([])
    f.advance(30_000)
    expect(f.annotate(gateway(running, { ...args, code: "other" }))).toEqual([])
    f.advance(1)
    const call = output({
      sessionUpdate: "tool_call",
      toolCallId: "call-1",
      title: "codevisor_execute",
      rawInput: args
    })
    expect(f.annotate(call)).toEqual([call])
    expect(f.annotate(output({ kind: "codevisor_execution", argsHash: 7 }))).toEqual([])
  })

  it("keeps a bounded buffer of early gateway states per session", () => {
    const f = fixture()
    for (let index = 0; index <= 16; index += 1) {
      f.annotate(gateway(running, { ...args, code: `code ${index}` }))
    }
    const call = (index: number) =>
      output({
        sessionUpdate: "tool_call",
        toolCallId: `call-${index}`,
        title: "codevisor.execute",
        rawInput: { ...args, code: `code ${index}` }
      })
    expect(f.annotate(call(0))).toHaveLength(1)
    expect(f.annotate(call(16))).toHaveLength(2)
  })

  it("merges execution state into the harness's own _meta in both directions", () => {
    const f = fixture()
    f.annotate(
      output({
        sessionUpdate: "tool_call",
        toolCallId: "call-1",
        title: "codevisor.execute",
        rawInput: args,
        _meta: { harness: { toolName: "execute" } }
      })
    )
    expect(payloads(f.annotate(gateway(running)))).toEqual([
      expect.objectContaining({
        _meta: { harness: { toolName: "execute" }, codevisorExecution: running }
      })
    ])
    // A later harness _meta must not wipe the latest execution state.
    expect(
      payloads(
        f.annotate(
          output({
            sessionUpdate: "tool_call_update",
            toolCallId: "call-1",
            status: "completed",
            _meta: { harness: { elapsed: 3 }, codevisorExecution: completed }
          })
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "call-1",
        status: "completed",
        _meta: { harness: { elapsed: 3 }, codevisorExecution: running }
      }
    ])
  })

  it("leaves other tools untouched and waits for complete streamed input", () => {
    const f = fixture()
    const other = output({ sessionUpdate: "tool_call", toolCallId: "bash", title: "Bash" })
    const untitled = output({ sessionUpdate: "tool_call_update", toolCallId: "late" })
    const chunk = output({ sessionUpdate: "agent_message_chunk", content: { text: "hi" } })
    const noPayload: RuntimeEvent = { kind: "session.output", subjectId: "subject", payload: 3 }
    for (const event of [other, untitled, chunk, noPayload]) {
      expect(f.annotate(event)).toEqual([event])
    }
    const partial = { code: "async () => tools.linear.list()" }
    f.annotate(
      output({
        sessionUpdate: "tool_call",
        toolCallId: "call-1",
        title: "codevisor.execute",
        status: "pending",
        rawInput: partial
      })
    )
    f.annotate(
      output({ sessionUpdate: "tool_call_update", toolCallId: "call-1", rawInput: "not input" })
    )
    expect(f.annotate(gateway(running, partial))).toEqual([])
    f.annotate(
      output({
        sessionUpdate: "tool_call_update",
        toolCallId: "call-1",
        status: "in_progress",
        rawInput: partial
      })
    )
    expect(f.annotate(gateway(completed, partial))).toHaveLength(1)
  })

  it("re-correlates when the harness revises a call's arguments", () => {
    const f = fixture()
    const call = (input: unknown) =>
      output({
        sessionUpdate: "tool_call_update",
        toolCallId: "call-1",
        title: "codevisor.execute",
        rawInput: input
      })
    f.annotate(call({ ...args, code: "draft" }))
    f.annotate(call(args))
    expect(f.annotate(gateway(running, { ...args, code: "draft" }))).toEqual([])
    expect(f.annotate(gateway(running))).toHaveLength(1)
  })

  it("forgets the oldest calls beyond its per-session bound and everything at session end", () => {
    const f = fixture()
    const call = (index: number, rawInput?: unknown) =>
      output({
        sessionUpdate: "tool_call",
        toolCallId: `call-${index}`,
        title: "codevisor.execute",
        ...(rawInput === undefined ? {} : { rawInput })
      })
    f.annotate(call(0, args))
    // Evicting one call forgets only its own arguments.
    f.annotate(call(1, { ...args, code: "second" }))
    for (let index = 2; index <= 65; index += 1) f.annotate(call(index))
    expect(f.annotate(gateway(running))).toEqual([])
    f.annotate(call(66, { ...args, code: "latest" }))
    expect(f.annotate(gateway(running, { ...args, code: "latest" }))).toHaveLength(1)
    f.annotator.endSession("session")
    expect(f.annotate(gateway(running, { ...args, code: "latest" }))).toEqual([])
  })
})

describe("ExecutionAnnotator with OpenCode's Code Mode", () => {
  /// OpenCode's own code tool: plain `execute`, running OpenCode's script,
  /// from inside which the model calls the gateway.
  const host = (fields: Record<string, unknown>) =>
    output({ toolCallId: "oc-1", title: "execute", ...fields })
  const labeled: CodevisorExecutionState = { ...running, description: args.description }

  it("attaches the gateway's runs to the Code Mode row that ran them", () => {
    const f = fixture()
    const started = host({ sessionUpdate: "tool_call", status: "pending", rawInput: {} })
    expect(f.annotate(started)).toEqual([started])
    // Not running code yet: a gateway run can't be its own.
    expect(f.annotate(gateway(labeled))).toEqual([])
    const code = { code: "await tools.codevisor.execute({ description, code })" }
    const runs = host({ sessionUpdate: "tool_call_update", status: "in_progress", rawInput: code })
    // Once it runs, the run that arrived first is its own.
    expect(payloads(f.annotate(runs))).toEqual([
      runs.payload,
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "oc-1",
        _meta: { codevisorExecution: labeled }
      }
    ])
    // Later updates of that run, and new runs from the same script, follow.
    const second = { description: "Then list my machines", code: "machines.list()" }
    const secondRun: CodevisorExecutionState = {
      state: "running",
      description: second.description,
      calls: []
    }
    expect(payloads(f.annotate(gateway(secondRun, second)))).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "oc-1",
        _meta: { codevisorExecution: secondRun }
      }
    ])
    const done = { ...completed, description: args.description }
    expect(payloads(f.annotate(gateway(done)))).toEqual([
      { sessionUpdate: "tool_call_update", toolCallId: "oc-1", _meta: { codevisorExecution: done } }
    ])
    // The row's own updates keep the state, and the harness's _meta.
    expect(
      payloads(
        f.annotate(
          host({
            sessionUpdate: "tool_call_update",
            status: "in_progress",
            rawInput: code,
            _meta: { opencode: 1 }
          })
        )
      )
    ).toEqual([
      {
        toolCallId: "oc-1",
        title: "execute",
        sessionUpdate: "tool_call_update",
        status: "in_progress",
        rawInput: code,
        _meta: { opencode: 1, codevisorExecution: done }
      }
    ])
    // Once it settles, a later run is no longer its own.
    f.annotate(host({ sessionUpdate: "tool_call_update", status: "completed" }))
    expect(f.annotate(gateway(running, { description: "Later", code: "x" }))).toEqual([])
  })

  it("leaves a Code Mode row alone when the gateway isn't involved", () => {
    const f = fixture()
    const update = host({
      sessionUpdate: "tool_call_update",
      status: "in_progress",
      rawInput: { code: "1 + 1" }
    })
    expect(f.annotate(host({ sessionUpdate: "tool_call", status: "pending" }))).toHaveLength(1)
    expect(f.annotate(update)).toEqual([update])
    // Running again changes nothing.
    expect(f.annotate(update)).toEqual([update])
    const failed = host({ sessionUpdate: "tool_call_update", status: "failed" })
    expect(f.annotate(failed)).toEqual([failed])
  })
})

describe("session event sink execution annotation", () => {
  it("publishes live execution state on the tool row and clears it with the turn", async () => {
    const { services } = await makeServices("execution-annotator")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-execution-annotator-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const fanout = await run(makeEventFanout)
    const published: Array<EventEnvelope> = []
    fanout.subscribe((event) => published.push(event))
    const sink = sessionEventSink(
      services as unknown as CodevisorServerServices,
      fanout,
      "execution-annotator",
      session.id
    )
    const emit = (payload: Record<string, unknown>) =>
      sink({ kind: "session.output", subjectId: session.id, payload })
    await sink({
      kind: "session.updated",
      subjectId: session.id,
      payload: { turnId: "turn-1", turnState: "started" }
    })
    await emit({ kind: "codevisor_execution", argsHash: argsHash(args), execution: running })
    await emit({
      sessionUpdate: "tool_call",
      toolCallId: "call-1",
      title: "codevisor.execute",
      status: "in_progress",
      rawInput: args
    })
    await emit({ kind: "codevisor_execution", argsHash: argsHash(args), execution: completed })
    await emit({ sessionUpdate: "tool_call_update", toolCallId: "call-1", status: "completed" })

    const rows = published
      .map((event) => event.payload as Record<string, unknown>)
      .filter((payload) => payload.toolCallId === "call-1")
    expect(rows.map((row) => row._meta)).toEqual([
      undefined,
      { codevisorExecution: running },
      { codevisorExecution: completed },
      { codevisorExecution: completed }
    ])
    expect(rows.at(-1)).toMatchObject({ isSnapshot: true, status: "completed", rawInput: args })
    expect(published.some((event) => JSON.stringify(event).includes("codevisor_execution"))).toBe(
      false
    )

    await sink({
      kind: "session.updated",
      subjectId: session.id,
      payload: { turnId: "turn-1", turnState: "ended", stopReason: "end_turn" }
    })
    const before = published.length
    await emit({ kind: "codevisor_execution", argsHash: argsHash(args), execution: running })
    expect(published).toHaveLength(before)
  })
})
