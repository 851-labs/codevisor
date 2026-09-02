import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { makeTerminalManager } from "./index.js"
import { run, makeSpawner } from "./test-support.js"

describe("@codevisor/terminal terminal manager shell resolution", () => {
  it("launches macOS shells with the bundled Ghostty terminal environment", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: {
        COLORTERM: "legacy",
        TERM: "xterm-256color",
        TERMINFO: "/tmp/missing",
        TERM_PROGRAM: "other"
      },
      platform: "darwin",
      spawner
    })

    await run(
      manager.createTerminal(
        { sessionId: "session-ghostty", cwd: "/tmp", cols: 80, rows: 24 },
        { TERM: "vt100" }
      )
    )

    const terminalEnv = spawner.requests[0]?.env
    expect(terminalEnv).toMatchObject({
      COLORTERM: "truecolor",
      TERM: "xterm-ghostty",
      TERM_PROGRAM: "ghostty"
    })
    const terminfoDirectory = terminalEnv?.TERMINFO
    expect(terminfoDirectory).toBeTypeOf("string")
    // Darwin's ncurses uses hexadecimal bucket names while Linux ncurses uses
    // the terminal name's first character. Ship both so the same server
    // package works on every supported host without distro-specific probing.
    expect(existsSync(join(terminfoDirectory!, "78", "xterm-ghostty"))).toBe(true)
    expect(existsSync(join(terminfoDirectory!, "67", "ghostty"))).toBe(true)
    expect(existsSync(join(terminfoDirectory!, "x", "xterm-ghostty"))).toBe(true)
    expect(existsSync(join(terminfoDirectory!, "g", "ghostty"))).toBe(true)
    expect(readFileSync(join(terminfoDirectory!, "x", "xterm-ghostty"))).toEqual(
      readFileSync(join(terminfoDirectory!, "78", "xterm-ghostty"))
    )
    expect(readFileSync(join(terminfoDirectory!, "g", "ghostty"))).toEqual(
      readFileSync(join(terminfoDirectory!, "67", "ghostty"))
    )
  })

  it("uses the portable 256-color terminal name for Linux profiles", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: { TERM: "xterm-ghostty" },
      platform: "linux",
      spawner
    })

    await run(
      manager.createTerminal({
        sessionId: "session-linux-term",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    expect(spawner.requests[0]?.env).toMatchObject({
      COLORTERM: "truecolor",
      TERM: "xterm-256color",
      TERM_PROGRAM: "ghostty"
    })
    expect(spawner.requests[0]?.env.TERMINFO).toBeUndefined()
  })

  it("prefers an executable SHELL from the manager environment", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: { SHELL: "/bin/zsh" },
      executableExists: () => true,
      userShell: () => "/bin/bash",
      spawner
    })

    await run(
      manager.createTerminal({
        sessionId: "session-env-shell",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    expect(spawner.requests[0]?.shell).toBe("/bin/zsh")
  })

  it("uses the passwd shell when a service environment has no SHELL", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: {},
      executableExists: (path) => path === "/usr/bin/fish",
      userShell: () => "/usr/bin/fish",
      spawner
    })

    await run(
      manager.createTerminal({
        sessionId: "session-passwd-shell",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    expect(spawner.requests[0]?.shell).toBe("/usr/bin/fish")
  })

  it("skips unusable discovered shells and falls back to /bin/sh", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: { SHELL: "/missing/env-shell" },
      executableExists: () => false,
      userShell: () => "/missing/passwd-shell",
      spawner
    })

    await run(
      manager.createTerminal({
        sessionId: "session-fallback-shell",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    expect(spawner.requests[0]?.shell).toBe("/bin/sh")
  })

  it("falls back when an automatically discovered shell is not executable", async () => {
    const spawner = makeSpawner()
    const manager = makeTerminalManager({
      env: { SHELL: "/codevisor-test/missing-shell" },
      userShell: () => undefined,
      spawner
    })

    await run(
      manager.createTerminal({
        sessionId: "session-missing-shell",
        cwd: "/tmp/project",
        cols: 80,
        rows: 24
      })
    )

    expect(spawner.requests[0]?.shell).toBe("/bin/sh")
  })
})
