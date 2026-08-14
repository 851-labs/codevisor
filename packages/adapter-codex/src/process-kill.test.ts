import { describe, expect, it } from "vitest"
import { commandSubtreePids, parseProcessTable } from "./process-kill.js"

describe("codex process-tree kill", () => {
  it("parses ps output into pid/ppid/command entries", () => {
    const table = parseProcessTable(
      [
        "  100     1 /usr/bin/codex app-server",
        "  200   100 /bin/bash -c npm run dev",
        "junk"
      ].join("\n")
    )
    expect(table).toEqual([
      { command: "/usr/bin/codex app-server", pid: 100, ppid: 1 },
      { command: "/bin/bash -c npm run dev", pid: 200, ppid: 100 }
    ])
  })

  it("collects matching descendants of the codex pid with their subtrees", () => {
    const table = parseProcessTable(
      [
        "  100     1 codex app-server",
        "  200   100 /bin/bash -c npm run dev",
        "  201   200 node dev-server.js",
        "  202   201 node worker.js",
        // Same command elsewhere in the system: NOT under codex, never killed.
        "  900     1 /bin/bash -c npm run dev",
        // Unrelated codex child.
        "  300   100 /bin/bash -c git status"
      ].join("\n")
    )
    expect(commandSubtreePids(table, 100, "npm run dev").sort()).toEqual([200, 201, 202])
    // No descendants match → nothing to kill.
    expect(commandSubtreePids(table, 100, "cargo build")).toEqual([])
    // Empty command never matches everything.
    expect(commandSubtreePids(table, 100, "  ")).toEqual([])
  })

  it("falls back to the command's first line when the full script does not match", () => {
    const table = parseProcessTable(["  100     1 codex", "  200   100 sh -c npm start"].join("\n"))
    expect(commandSubtreePids(table, 100, "npm start\nnpm run extra")).toEqual([200])
  })
})
