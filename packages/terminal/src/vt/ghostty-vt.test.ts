import { describe, expect, it, vi } from "vitest"

import { createVtTerminal, loadGhosttyVt } from "./ghostty-vt.js"

const decode = (bytes: Uint8Array): string => new TextDecoder().decode(bytes)

describe("libghostty-vt terminal state", () => {
  it("loads the bundled wasm build on first use and ignores empty writes", () => {
    const terminal = createVtTerminal({ cols: 20, rows: 4 })
    terminal.write("")
    terminal.write("ready")
    expect(terminal.text()).toBe("ready")
    terminal.free()
  })

  it("reconstructs screen, scrollback, style, and cursor into a fresh terminal", () => {
    const source = createVtTerminal({ cols: 40, rows: 5 })
    for (let line = 0; line < 30; line += 1) {
      source.write(`\u001b[3${line % 8}mline ${line}\u001b[0m\r\n`)
    }
    source.write("prompt$ \u001b[?25l")
    const replica = createVtTerminal({ cols: 40, rows: 5 })
    replica.write("stale output\r\nthat must disappear")
    replica.write(source.reconstruct())

    expect(replica.text()).toBe(source.text())
    expect(replica.text().split("\n")).toHaveLength(31)
    expect(replica.state()).toEqual(source.state())
    expect(source.state()).toMatchObject({ cols: 40, rows: 5, cursorVisible: false })
    source.free()
    replica.free()
  })

  it("carries an escape sequence split across writes into the reconstruction", () => {
    const source = createVtTerminal({ cols: 20, rows: 3 })
    source.write("a\u001b[3")
    const replica = createVtTerminal({ cols: 20, rows: 3 })
    replica.write(source.reconstruct())
    source.write("1mb")
    replica.write("1mb")
    expect(replica.text()).toBe("ab")
    expect(decode(replica.reconstruct())).toBe(decode(source.reconstruct()))
    source.free()
    replica.free()
  })

  it("answers terminal queries through the reply callback", () => {
    const replies: Array<string> = []
    const terminal = createVtTerminal({
      cols: 20,
      rows: 3,
      onReply: (reply) => replies.push(decode(reply))
    })
    terminal.write("ab\u001b[6n")
    expect(replies).toEqual(["\u001b[1;3R"])
    const silent = createVtTerminal({ cols: 20, rows: 3 })
    silent.write("\u001b[6n")
    expect(replies).toHaveLength(1)
    terminal.free()
    silent.free()
  })

  it("tracks resizes and the alternate screen", () => {
    const terminal = createVtTerminal({ cols: 20, rows: 3 })
    terminal.resize(30, 6)
    terminal.write("\u001b[?1049hfull screen app")
    expect(terminal.state()).toMatchObject({ cols: 30, rows: 6, alternateScreen: true })
    expect(() => terminal.resize(0, 0)).toThrow(/terminal_resize/)
    terminal.free()
  })

  it("reports the title programs set with OSC 0 and 2", () => {
    const terminal = createVtTerminal({ cols: 20, rows: 3 })
    expect(terminal.title()).toBe("")
    terminal.write("\u001b]2;hello\u0007")
    expect(terminal.title()).toBe("hello")
    terminal.write("\u001b]0;✳ Claude")
    terminal.write(" Code\u001b\\")
    expect(terminal.title()).toBe("✳ Claude Code")
    terminal.reconstruct()
    terminal.resize(30, 6)
    expect(terminal.title()).toBe("✳ Claude Code")
    terminal.write("\u001b]2;\u0007")
    expect(terminal.title()).toBe("")
    terminal.free()
  })

  it("refuses use after free, and freeing twice is harmless", () => {
    const terminal = createVtTerminal({ cols: 10, rows: 2, onReply: () => undefined })
    terminal.free()
    terminal.free()
    expect(() => terminal.write("x")).toThrow(/freed/)
  })

  it("keeps working once its heap passes 2 GiB, and reports exhaustion", () => {
    let heap: { ghostty_wasm_alloc: (len: number) => number } | undefined
    const Instance = WebAssembly.Instance
    vi.stubGlobal(
      "WebAssembly",
      Object.create(WebAssembly, {
        Instance: {
          value: function (module: WebAssembly.Module, imports: WebAssembly.Imports) {
            const instance = new Instance(module, imports)
            if ("ghostty_wasm_alloc" in instance.exports) heap ??= instance.exports as never
            return instance
          }
        }
      })
    )
    try {
      loadGhosttyVt()
      const chunk = 64 * 1024 * 1024
      let ptr: number
      do ptr = heap!.ghostty_wasm_alloc(chunk)
      while (ptr > 0)
      expect(ptr).toBeLessThan(0)

      const replies: Array<string> = []
      const terminal = createVtTerminal({
        cols: 20,
        rows: 3,
        onReply: (reply) => replies.push(decode(reply))
      })
      terminal.write("\u001b]2;high\u0007ab\u001b[6n")
      expect(terminal.text()).toBe("ab")
      expect(terminal.title()).toBe("high")
      expect(replies).toEqual(["\u001b[1;3R"])
      expect(decode(terminal.reconstruct())).toContain("ab")

      for (let size = chunk; size >= 1; size = Math.floor(size / 2)) {
        while (heap!.ghostty_wasm_alloc(size) !== 0) {}
      }
      expect(() => terminal.write("more")).toThrow(/out of memory/)
      expect(() => createVtTerminal({ cols: 20, rows: 3 })).toThrow(/out of memory/)
    } finally {
      vi.unstubAllGlobals()
      loadGhosttyVt()
    }
  })
})
