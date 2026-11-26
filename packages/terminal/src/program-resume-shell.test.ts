import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { makeTerminalManager } from "./index.js"
import { inputFrame, run } from "./test-support.js"

const temporaryDirectory = (prefix: string): string => {
  const directory = mkdtempSync(join(tmpdir(), prefix))
  onTestFinished(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}

describe.skipIf(!existsSync("/bin/zsh"))("resuming a program in zsh", () => {
  it(
    "runs the command after startup files as a job of the shell, then returns to the prompt",
    { timeout: 30_000 },
    async () => {
      const home = temporaryDirectory("codevisor-resume-home-")
      const project = temporaryDirectory("codevisor-resume-project-")
      writeFileSync(join(home, ".zshrc"), "PROMPT='ready> '\nprintf() { echo hijacked }\n")
      const manager = makeTerminalManager({
        defaultShell: "/bin/zsh",
        env: { HOME: home, PATH: process.env.PATH ?? "/usr/bin:/bin" }
      })
      const uid = process.getuid!()
      manager.restoreTerminals({
        version: 4,
        terminals: [
          {
            terminalId: "resumed",
            sessionId: "pane",
            nextOutputSeq: 1,
            closed: false,
            external: false,
            cols: 80,
            rows: 24,
            launch: { cwd: home },
            resume: {
              argv: ["printf", "[%s]", "a  b", "", "$(echo x)", "pwd:"],
              cwd: project,
              cwdFromReport: true,
              uid
            }
          }
        ]
      })

      let output = ""
      const prompted = Promise.withResolvers<void>()
      const exited = Promise.withResolvers<void>()
      await run(
        manager.connectTerminal("resumed", 0, (frame) => {
          if (frame.type === "exit") exited.resolve()
          if (frame.type !== "output") return
          output += frame.data
          if (/\[pwd:\][^]*ready> /u.test(output)) prompted.resolve()
        })
      )
      await prompted.promise
      await run(manager.handleClientFrame("resumed", inputFrame(1, "exit\r")))
      await exited.promise

      expect(output).toContain("[a  b][][$(echo x)][pwd:]")
      expect(output).not.toContain("hijacked")
    }
  )
})
