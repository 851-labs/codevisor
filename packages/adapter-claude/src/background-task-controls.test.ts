import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import {
  payloadOf,
  recordsValue,
  resultMessage,
  run,
  sdkMessage,
  startTestSession,
  streamEvent,
  systemMessage
} from "./test-support.js"

const tempDirs: Array<string> = []

const outputFile = (contents: string): string => {
  const directory = mkdtempSync(join(tmpdir(), "claude-task-output-"))
  tempDirs.push(directory)
  const path = join(directory, "bg-1.output")
  writeFileSync(path, contents)
  return path
}

const toolResult = (content: unknown) =>
  sdkMessage({
    message: {
      content: [{ content, is_error: false, tool_use_id: "tool-bash-1", type: "tool_result" }],
      role: "user"
    },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "user"
  })

const backgroundResult = (path: string): string =>
  `Command running in background with ID: bg-1. Output is being written to: ${path}. You will be notified when it completes.`

const startBackgroundShell = async (resultContent: (path: string) => unknown, contents: string) => {
  const session = await startTestSession()
  const { fake, created } = session
  const path = outputFile(contents)
  const promptPromise = run(created.handle.prompt("tick in the background"))
  await fake.nextPrompt()
  fake.push(
    streamEvent({
      content_block: { id: "tool-bash-1", input: {}, name: "Bash", type: "tool_use" },
      index: 0,
      type: "content_block_start"
    })
  )
  fake.push(
    streamEvent({
      delta: {
        partial_json: '{"command":"seq 3","run_in_background":true}',
        type: "input_json_delta"
      },
      index: 0,
      type: "content_block_delta"
    })
  )
  fake.push(
    systemMessage("task_started", {
      description: "Count to three",
      task_id: "bg-1",
      task_type: "local_bash",
      tool_use_id: "tool-bash-1"
    })
  )
  fake.push(toolResult(resultContent(path)))
  fake.push(resultMessage())
  await promptPromise
  await fake.drain()
  return session
}

const latestTasks = (events: ReadonlyArray<Parameters<typeof payloadOf>[0]>) =>
  events
    .map(payloadOf)
    .filter((payload) => Array.isArray(payload.backgroundTasks))
    .map((payload) => recordsValue(payload.backgroundTasks))
    .at(-1)

const readOutput = (
  created: Awaited<ReturnType<typeof startTestSession>>["created"],
  taskId: string,
  lineLimit: number
) => Effect.runPromise(created.handle.readTaskOutput!(taskId, lineLimit))

describe("background task controls", () => {
  afterEach(() => {
    for (const directory of tempDirs.splice(0)) rmSync(directory, { force: true, recursive: true })
  })

  it("reports a background shell's command and reads the tail of its output", async () => {
    const { events, created } = await startBackgroundShell(
      backgroundResult,
      "tick 1\ntick 2\ntick 3\n"
    )

    expect(latestTasks(events)).toEqual([
      expect.objectContaining({ canStop: true, command: "seq 3", hasOutput: true, id: "bg-1" })
    ])
    expect(await readOutput(created, "bg-1", 2)).toEqual(["tick 2", "tick 3"])
    expect(await readOutput(created, "unknown", 2)).toBeUndefined()
  })

  it("reads output named in a tool result's text blocks", async () => {
    const { created } = await startBackgroundShell(
      (path) => [{ text: backgroundResult(path), type: "text" }, { type: "image" }],
      "done\n"
    )

    expect(await readOutput(created, "bg-1", 50)).toEqual(["done"])
  })

  it("drops the partial first line when the output is longer than the tail it reads", async () => {
    const { created } = await startBackgroundShell(
      backgroundResult,
      `${"x".repeat(70_000)}\nlast\n`
    )

    expect(await readOutput(created, "bg-1", 50)).toEqual(["last"])
  })

  it("reads no lines once the output file is gone, and forgets it when the task ends", async () => {
    const { fake, events, created } = await startBackgroundShell(backgroundResult, "")
    rmSync(tempDirs[0]!, { force: true, recursive: true })

    expect(await readOutput(created, "bg-1", 50)).toEqual([])

    fake.push(systemMessage("task_notification", { status: "completed", task_id: "bg-1" }))
    await fake.drain()
    expect(latestTasks(events)).toEqual([])
    expect(await readOutput(created, "bg-1", 50)).toBeUndefined()
  })

  it("stops a single task through the SDK", async () => {
    const { fake, created } = await startTestSession()

    await Effect.runPromise(created.handle.stopTask!("bg-1"))

    expect(fake.stoppedTasks).toEqual(["bg-1"])
  })
})
