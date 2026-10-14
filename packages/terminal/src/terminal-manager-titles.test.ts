import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { makeTerminalManager, type TerminalManagerService } from "./index.js"
import { closeFrame, FakeProcess, makeSpawner, run } from "./test-support.js"

const osc = (title: string): string => `\u001b]2;${title}\u0007`
const mark = (kind: string): string => `\u001b]133;${kind}\u0007`
const report = (body: string): string => `\u001b]7501;${body}\u001b\\`

const subscribed = (manager: TerminalManagerService) => {
  const titles: Array<[string, string | undefined, string?]> = []
  const unsubscribe = manager.subscribeTitles((key, { title, activity }) =>
    titles.push(activity === undefined ? [key, title] : [key, title, activity])
  )
  return { titles, unsubscribe }
}

const shell = async (sessionId = "Term-1") => {
  const spawner = makeSpawner()
  const manager = makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
  const created = await run(manager.createTerminal({ sessionId, cwd: "/tmp", cols: 80, rows: 24 }))
  return { manager, spawner, created, output: spawner.handlers[0]!.onOutput }
}

describe("@codevisor/terminal settled titles", () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("publishes a title once it has held for 500 ms", async () => {
    const { manager, output } = await shell()
    const { titles, unsubscribe } = subscribed(manager)

    output(`${osc("vim")}text`)
    vi.advanceTimersByTime(499)
    expect(titles).toEqual([])
    vi.advanceTimersByTime(1)
    expect(titles).toEqual([["Term-1", "vim"]])

    output("more text")
    vi.advanceTimersByTime(1000)
    expect(titles).toHaveLength(1)

    output(osc(""))
    vi.advanceTimersByTime(500)
    expect(titles.at(-1)).toEqual(["Term-1", undefined])

    unsubscribe()
    output(osc("after"))
    vi.advanceTimersByTime(500)
    expect(titles).toHaveLength(2)
  })

  it("drops the title a shell sets at its prompt, keeping those set while a command runs", async () => {
    const { manager, output } = await shell()
    const { titles } = subscribed(manager)

    output(`${osc("me@host:~/code")}${mark("A")}➜ ${mark("B")}`)
    vi.advanceTimersByTime(1000)
    expect(titles).toEqual([])

    output(`${osc("npm run dev")}${mark("C")}ready`)
    vi.advanceTimersByTime(500)
    expect(titles).toEqual([["Term-1", "npm run dev"]])

    output(`${mark("D;0")}${osc("me@host:~/code")}${mark("A")}➜ `)
    vi.advanceTimersByTime(500)
    expect(titles.at(-1)).toEqual(["Term-1", undefined])
  })

  it("settles an agent's title and activity, not its spinner frames", async () => {
    const { manager, output } = await shell()
    const { titles } = subscribed(manager)

    output(osc("⠂ Claude Code"))
    for (const glyph of ["⠐", "⠂", "⠐", "⠂", "⠐", "⠂", "⠐", "⠂", "⠐"]) {
      vi.advanceTimersByTime(100)
      output(osc(`${glyph} Claude Code`))
    }
    expect(titles).toEqual([["Term-1", "Claude Code", "working"]])

    output(osc("✳ Claude Code"))
    vi.advanceTimersByTime(499)
    expect(titles).toHaveLength(1)
    vi.advanceTimersByTime(1)
    expect(titles.at(-1)).toEqual(["Term-1", "Claude Code", "idle"])

    output(osc("◐ Claude Code"))
    vi.advanceTimersByTime(300)
    output(osc("✳ Claude Code"))
    vi.advanceTimersByTime(1000)
    expect(titles).toHaveLength(2)
  })

  it("clears a shell's title when it exits, dropping any unsettled one", async () => {
    const { manager, spawner, output } = await shell()
    const { titles } = subscribed(manager)
    output(osc("make"))
    vi.advanceTimersByTime(500)
    output(osc("make test"))
    spawner.handlers[0]!.onExit(0)
    vi.advanceTimersByTime(1000)
    expect(titles).toEqual([
      ["Term-1", "make"],
      ["Term-1", undefined]
    ])
  })

  it("clears the title when a client closes the terminal", async () => {
    const { manager, created, output } = await shell()
    const { titles } = subscribed(manager)
    output(osc("htop"))
    vi.advanceTimersByTime(500)
    await run(manager.handleClientFrame(created.terminalId, closeFrame(1)))
    expect(titles).toEqual([
      ["Term-1", "htop"],
      ["Term-1", undefined]
    ])
  })

  it("publishes nothing for terminals that never had a title", async () => {
    const { manager, spawner, output } = await shell()
    const { titles } = subscribed(manager)
    output("plain output")
    spawner.handlers[0]!.onExit(0)
    vi.advanceTimersByTime(1000)

    const restored = makeTerminalManager({ spawner: makeSpawner() })
    const restoredTitles = subscribed(restored).titles
    restored.restoreTerminals({
      version: 2,
      terminals: [
        {
          terminalId: "restored",
          sessionId: "Term-2",
          nextOutputSeq: 2,
          closed: false,
          external: false,
          screen: osc("stale")
        }
      ]
    })
    vi.advanceTimersByTime(1000)
    expect(titles).toEqual([])
    expect(restoredTitles).toEqual([])
  })

  it("follows external terminals until they exit or are replaced", async () => {
    const manager = makeTerminalManager({ spawner: makeSpawner() })
    const { titles } = subscribed(manager)
    const first = manager.registerExternalTerminal({ sessionId: "agent:bg:1" }, new FakeProcess())
    first.output(osc("server"))
    vi.advanceTimersByTime(500)
    const second = manager.registerExternalTerminal({ sessionId: "agent:bg:1" }, new FakeProcess())
    second.output(osc("server 2"))
    vi.advanceTimersByTime(500)
    second.exit(0)
    second.output(osc("late"))
    vi.advanceTimersByTime(500)
    expect(titles).toEqual([
      ["agent:bg:1", "server"],
      ["agent:bg:1", undefined],
      ["agent:bg:1", "server 2"],
      ["agent:bg:1", undefined]
    ])
  })
})

describe("@codevisor/terminal program status (OSC 7501)", () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it("answers the support query for live terminals, whether or not a client is attached", async () => {
    const { manager, spawner, created, output } = await shell()
    output("\u001b]7501;?\u0007")
    const disconnect = await run(manager.connectTerminal(created.terminalId, 0, () => undefined))
    output("\u001b]7501;?\u001b\\")
    disconnect()
    expect(spawner.processes[0]!.writes).toEqual([
      "\u001b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u0007",
      "\u001b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u001b\\"
    ])
  })

  it("publishes what a program reports in place of what its title suggests", async () => {
    const { manager, output } = await shell()
    const { titles } = subscribed(manager)

    output(`${mark("C")}${osc("⠂ Claude Code")}${report("state=blocked:kind=permission")}`)
    vi.advanceTimersByTime(500)
    expect(titles).toEqual([["Term-1", "Claude Code", "blocked"]])

    output(report("state=clear"))
    vi.advanceTimersByTime(500)
    expect(titles.at(-1)).toEqual(["Term-1", "Claude Code", "working"])
  })

  it("keeps done and error past the shell prompt, and drops the rest", async () => {
    const { manager, output } = await shell()
    const { titles } = subscribed(manager)

    output(`${mark("C")}${report("state=working:app=terraform")}`)
    vi.advanceTimersByTime(500)
    output(`${mark("D;0")}${mark("A")}➜ `)
    vi.advanceTimersByTime(500)
    expect(titles).toEqual([
      ["Term-1", undefined, "working"],
      ["Term-1", undefined]
    ])

    output(`${mark("C")}${report("state=done")}${mark("D;0")}${mark("A")}➜ `)
    vi.advanceTimersByTime(500)
    expect(titles.at(-1)).toEqual(["Term-1", undefined, "done"])
    output(`${mark("C")}ls${mark("D;0")}${mark("A")}➜ `)
    vi.advanceTimersByTime(500)
    expect(titles.at(-1)).toEqual(["Term-1", undefined, "done"])

    output("\u001bc")
    vi.advanceTimersByTime(500)
    expect(titles.at(-1)).toEqual(["Term-1", undefined])
  })
})
