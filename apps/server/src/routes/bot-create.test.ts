import { describe, expect, it } from "vitest"

import { upgradeBotInstructions } from "./bot-create.js"

const legacy = [
  "# Helper",
  "",
  "You are a long-lived Codevisor bot.",
  "",
  "## Repositories",
  "",
  "- `api/`: api",
  "",
  "## Delegating work",
  "",
  "1. `worktrees.create({ projectId })`",
  "2. `sessions.create({ projectId, worktreeName, title })`",
  "3. `sessions.prompt({ sessionId, text })`",
  "4. `sessions.wait` or `sessions.get` to follow up",
  ""
].join("\n")

describe("bot instructions", () => {
  it("teach an existing bot to message the user and wait for agent events, once", () => {
    const upgraded = upgradeBotInstructions(legacy, "claude-code")

    expect(upgraded.indexOf("## Talking to the user")).toBeLessThan(
      upgraded.indexOf("## Repositories")
    )
    expect(upgraded).toContain(
      '`sessions.create({ projectId, worktreeName, harnessId: "claude-code", title })`'
    )
    expect(upgraded).toContain("4. End your turn.")
    expect(upgraded).not.toContain("sessions.wait")
    expect(upgradeBotInstructions(upgraded, "claude-code")).toBe(upgraded)
  })
})
