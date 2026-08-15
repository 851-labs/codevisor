import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { makeCodexProvider } from "./provider.js"
import { definition, environment, FakeCodexClient, run } from "./test-support.js"

describe("CodexProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("mirrors command output into background terminals and promotes long-lived commands", async () => {
    vi.useFakeTimers()
    const client = new FakeCodexClient()
    const kills: Array<{ rootPid: number; command: string }> = []
    const registered: Array<{
      key: string
      outputs: Array<string>
      exits: Array<number | undefined>
      removed: boolean
      kill: (() => void) | undefined
    }> = []
    const provider = makeCodexProvider(environment, {
      backgroundTerminals: {
        promotionDelayMs: 50,
        registry: {
          register: (key, controls) => {
            const entry = {
              exits: [],
              key,
              kill: controls.kill,
              outputs: [],
              removed: false
            } as (typeof registered)[0]
            registered.push(entry)
            return {
              exit: (exitCode) => entry.exits.push(exitCode),
              output: (data) => entry.outputs.push(data),
              remove: () => {
                entry.removed = true
              }
            }
          }
        }
      },
      connector: async () => client,
      killCommandProcesses: async (rootPid, command) => {
        kills.push({ command, rootPid })
      }
    })
    const events: Array<RuntimeEvent> = []
    const created = await run(
      provider.createSession(definition, "/tmp/project", async (event) => {
        events.push(event)
      })
    )
    const snapshots = () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map((event) => event.payload as Record<string, unknown>)
        .filter((payload) => Array.isArray(payload.backgroundTasks))
        .map((payload) => payload.backgroundTasks as Array<Record<string, unknown>>)
    // Session creation clears any stale replayed snapshot.
    expect(snapshots()).toEqual([[]])

    client.emit("item/started", {
      item: {
        command: "npm run dev",
        id: "item-dev",
        status: "inProgress",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/commandExecution/outputDelta", {
      delta: "ready on :3000\n",
      itemId: "item-dev",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // Deltas for unknown items are dropped.
    client.emit("item/commandExecution/outputDelta", {
      delta: "noise",
      itemId: "item-unknown",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(registered[0]?.key).toBe("thread-new:bg:item-dev")
    expect(registered[0]?.outputs).toEqual(["ready on :3000\n"])

    // The mirror's kill control walks the codex process tree (best effort).
    registered[0]?.kill?.()
    expect(kills).toEqual([{ command: "npm run dev", rootPid: 4242 }])

    // Still running after the promotion delay → surfaces as a task with a
    // terminal key.
    vi.advanceTimersByTime(50)
    expect(snapshots().at(-1)).toEqual([
      {
        description: "npm run dev",
        id: "item-dev",
        readOnly: true,
        status: "running",
        taskType: "shell",
        terminalKey: "thread-new:bg:item-dev",
        toolUseId: "item-dev"
      }
    ])

    // Completion ends the mirror, clears the task, and keeps the scrollback.
    client.emit("item/completed", {
      item: {
        command: "npm run dev",
        exitCode: 0,
        id: "item-dev",
        status: "completed",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(registered[0]?.exits).toEqual([0])
    expect(registered[0]?.removed).toBe(false)
    expect(snapshots().at(-1)).toEqual([])

    // A short-lived command never surfaces and leaves nothing behind.
    client.emit("item/started", {
      item: { command: "ls", id: "item-ls", status: "inProgress", type: "commandExecution" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { command: "ls", id: "item-ls", status: "completed", type: "commandExecution" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(registered[1]?.exits).toEqual([undefined])
    expect(registered[1]?.removed).toBe(true)
    vi.advanceTimersByTime(1000)
    expect(snapshots().at(-1)).toEqual([])

    // unifiedExecStartup is codex explicitly opening a persistent shell — it
    // surfaces as a task immediately, no promotion delay.
    client.emit("item/started", {
      item: {
        command: "npm run watch",
        id: "item-watch",
        source: "unifiedExecStartup",
        status: "inProgress",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(snapshots().at(-1)).toEqual([
      {
        description: "npm run watch",
        id: "item-watch",
        readOnly: true,
        status: "running",
        taskType: "shell",
        terminalKey: "thread-new:bg:item-watch",
        toolUseId: "item-watch"
      }
    ])
    client.emit("item/completed", {
      item: {
        command: "npm run watch",
        exitCode: 0,
        id: "item-watch",
        source: "unifiedExecStartup",
        status: "completed",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect(snapshots().at(-1)).toEqual([])

    // Session close ends any mirrors that are still running.
    client.emit("item/started", {
      item: { command: "sleep 99", id: "item-zzz", status: "inProgress", type: "commandExecution" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await run(created.handle.close)
    expect(registered[3]?.exits).toEqual([undefined])
    expect(registered[3]?.removed).toBe(true)
  })
})
