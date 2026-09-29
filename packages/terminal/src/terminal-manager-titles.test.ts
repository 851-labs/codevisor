import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { makeTerminalManager, type TerminalManagerService } from "./index.js"
import { closeFrame, FakeProcess, makeSpawner, run } from "./test-support.js"

const osc = (title: string): string => `\u001b]2;${title}\u0007`
/// A shell integration's semantic prompt mark.
const mark = (kind: string): string => `\u001b]133;${kind}\u0007`

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

    // Output that leaves the title alone publishes nothing more.
    output("more text")
    vi.advanceTimersByTime(1000)
    expect(titles).toHaveLength(1)

    // An emptied title clears it.
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

    // The theme names the terminal at every prompt: not a title worth showing.
    output(`${osc("me@host:~/code")}${mark("A")}➜ ${mark("B")}`)
    vi.advanceTimersByTime(1000)
    expect(titles).toEqual([])

    // A command runs: its title counts.
    output(`${osc("npm run dev")}${mark("C")}ready`)
    vi.advanceTimersByTime(500)
    expect(titles).toEqual([["Term-1", "npm run dev"]])

    // Back at the prompt, the terminal has no title again.
    output(`${mark("D;0")}${osc("me@host:~/code")}${mark("A")}➜ `)
    vi.advanceTimersByTime(500)
    expect(titles.at(-1)).toEqual(["Term-1", undefined])
  })

  it("settles an agent's title and activity, not its spinner frames", async () => {
    const { manager, output } = await shell()
    const { titles } = subscribed(manager)

    // Claude Code spins a braille glyph every ~100 ms while it works. Every
    // frame reads as the same (title, activity), so the first one settles
    // on schedule and the rest publish nothing.
    output(osc("⠂ Claude Code"))
    for (const glyph of ["⠐", "⠂", "⠐", "⠂", "⠐", "⠂", "⠐", "⠂", "⠐"]) {
      vi.advanceTimersByTime(100)
      output(osc(`${glyph} Claude Code`))
    }
    expect(titles).toEqual([["Term-1", "Claude Code", "working"]])

    // Back at its prompt.
    output(osc("✳ Claude Code"))
    vi.advanceTimersByTime(499)
    expect(titles).toHaveLength(1)
    vi.advanceTimersByTime(1)
    expect(titles.at(-1)).toEqual(["Term-1", "Claude Code", "idle"])

    // A turn shorter than the settle time never shows as working.
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

    // Restored terminals are closed scrollback: their screens never publish.
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
    // Re-registering under the same key ends the previous terminal.
    const second = manager.registerExternalTerminal({ sessionId: "agent:bg:1" }, new FakeProcess())
    second.output(osc("server 2"))
    vi.advanceTimersByTime(500)
    second.exit(0)
    // Output after the exit is scrollback only.
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
