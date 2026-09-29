import { readFileSync } from "node:fs"

import { describe, expect, it } from "vitest"

import { createVtTerminal, GHOSTTY_VT_WASM_PATH, loadGhosttyVt } from "./ghostty-vt.js"

const decode = (bytes: Uint8Array): string => new TextDecoder().decode(bytes)

describe("libghostty-vt terminal state", () => {
  it("loads the bundled wasm build, lazily or explicitly", () => {
    const lazy = createVtTerminal({ cols: 20, rows: 4 })
    lazy.free()
    loadGhosttyVt(readFileSync(GHOSTTY_VT_WASM_PATH))
    const terminal = createVtTerminal({ cols: 20, rows: 4 })
    terminal.write("")
    terminal.write("ready")
    expect(terminal.text()).toBe("ready")
    terminal.free()
  })

  it("reconstructs screen, scrollback, style, and cursor into a fresh terminal", () => {
    const source = createVtTerminal({ cols: 40, rows: 5, scrollbackLines: 1000 })
    for (let line = 0; line < 30; line += 1) {
      source.write(`\u001b[3${line % 8}mline ${line}\u001b[0m\r\n`)
    }
    source.write("prompt$ \u001b[?25l")
    // A renderer that already shows other output is reset first.
    const replica = createVtTerminal({ cols: 40, rows: 5, scrollbackLines: 1000 })
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
    // Live output resumes mid-sequence on both.
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
    // A terminal without a reply handler stays silent.
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

  it("refuses use after free, and freeing twice is harmless", () => {
    const terminal = createVtTerminal({ cols: 10, rows: 2, onReply: () => undefined })
    terminal.free()
    terminal.free()
    expect(() => terminal.write("x")).toThrow(/freed/)
  })
})
