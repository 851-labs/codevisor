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
  it("teach a conversational bot to message the user and wait for agent events, once", () => {
    const upgraded = upgradeBotInstructions(legacy, "claude-code", true)

    expect(upgraded.indexOf("## Talking to the user")).toBeLessThan(
      upgraded.indexOf("## Repositories")
    )
    expect(upgraded).toContain(
      '`sessions.create({ projectId, worktreeName, harnessId: "claude-code", title })`'
    )
    expect(upgraded).toContain("4. End your turn.")
    expect(upgraded).not.toContain("sessions.wait")
    expect(upgradeBotInstructions(upgraded, "claude-code", true)).toBe(upgraded)
  })

  it("keep a bot without conversation mode on its transcript and sessions.wait", () => {
    const conversational = upgradeBotInstructions(legacy, "codex", true)

    const plain = upgradeBotInstructions(conversational, "codex", false)

    expect(plain).not.toContain("## Talking to the user")
    expect(plain).toContain("4. `sessions.wait` or `sessions.get` to follow up")
    expect(plain).toContain('harnessId: "codex"')
    expect(upgradeBotInstructions(legacy, "codex", false)).toBe(plain)
  })
})
