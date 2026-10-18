import { readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { upgradeAllBotInstructions, upgradeBotInstructions } from "./bot-create.js"
import { createBot, decodeBot, setUp } from "./bot-test-support.js"

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

  it("upgrade every bot's instructions on startup, skipping bots whose file is gone", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    await running.addProject("web-project", "web")
    const chatty = decodeBot(
      (
        await createBot(running, {
          name: "Chatty",
          projectIds: ["api-project"],
          conversational: true
        })
      ).body
    )
    const missing = decodeBot(
      (await createBot(running, { name: "Missing", projectIds: ["web-project"] })).body
    )
    const instructions = join(chatty.rootPath, "AGENTS.md")
    writeFileSync(instructions, "# Chatty\n\nYou are a long-lived Codevisor bot.\n")
    rmSync(join(missing.rootPath, "AGENTS.md"))

    await upgradeAllBotInstructions(running.services)
    const upgraded = readFileSync(instructions, "utf8")
    await upgradeAllBotInstructions(running.services)

    expect(upgraded).toMatch(/You are a long-lived Codevisor bot\.\n\n## Talking to the user/)
    expect(readFileSync(instructions, "utf8")).toBe(upgraded)
  })
})
