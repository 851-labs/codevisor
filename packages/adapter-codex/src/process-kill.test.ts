import { describe, expect, it } from "vitest"

import { commandSubtreePids, type ProcessTableEntry } from "./process-kill.js"

const entry = (pid: number, ppid: number, command: string): ProcessTableEntry => ({
  command,
  pid,
  ppid
})

describe("codex process-tree kill", () => {
  it("collects matching descendants of the codex pid with their subtrees", () => {
    const table = [
      entry(100, 1, "codex app-server"),
      entry(200, 100, "/bin/bash -c npm run dev"),
      entry(201, 200, "node dev-server.js"),
      entry(202, 201, "node worker.js"),
      // Same command elsewhere in the system: NOT under codex, never killed.
      entry(900, 1, "/bin/bash -c npm run dev"),
      // Unrelated codex child.
      entry(300, 100, "/bin/bash -c git status")
    ]
    expect(commandSubtreePids(table, 100, "npm run dev").toSorted()).toEqual([200, 201, 202])
    // No descendants match → nothing to kill.
    expect(commandSubtreePids(table, 100, "cargo build")).toEqual([])
    // Empty command never matches everything.
    expect(commandSubtreePids(table, 100, "  ")).toEqual([])
  })

  it("falls back to the command's first line when the full script does not match", () => {
    const table = [entry(100, 1, "codex"), entry(200, 100, "sh -c npm start")]
    expect(commandSubtreePids(table, 100, "npm start\nnpm run extra")).toEqual([200])
  })
})
