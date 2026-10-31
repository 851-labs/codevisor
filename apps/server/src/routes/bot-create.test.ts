import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import {
  replaceRepositories,
  upgradeAllBotInstructions,
  upgradeBotInstructions
} from "./bot-instructions.js"
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
    const upgraded = upgradeBotInstructions(legacy, true)

    expect(upgraded.indexOf("## Talking to the user")).toBeLessThan(
      upgraded.indexOf("## Repositories")
    )
    expect(upgraded).toContain(
      '1. `machines.current.agents.start({ project: projectId, isolation: "worktree", title, prompt })`'
    )
    expect(upgraded).toContain("2. End your turn.")
    expect(upgraded).not.toContain("sessions.")
    expect(upgraded).not.toContain("worktrees.create")
    expect(upgradeBotInstructions(upgraded, true)).toBe(upgraded)
  })

  it("keep a bot without conversation mode on agents.status", () => {
    const conversational = upgradeBotInstructions(legacy, true)

    const plain = upgradeBotInstructions(conversational, false)

    expect(plain).not.toContain("## Talking to the user")
    expect(plain).toContain("2. `machines.current.agents.status({ agentId })`")
    expect(upgradeBotInstructions(legacy, false)).toBe(plain)
  })

  it("upgrade a bot written for the old messaging and event steps", () => {
    const eventBot = [
      "## Talking to the user",
      "",
      "The user chats with you like iMessage and only sees the messages you send with",
      "`codevisor.messages.send` through the Codevisor MCP. Nothing else you write reaches them, not",
      "even your final reply. Read the `codevisor-messages` skill before your first reply.",
      "",
      "## Delegating work",
      "",
      "1. `worktrees.create({ projectId })`",
      '2. `sessions.create({ projectId, worktreeName, harnessId: "codex", title })`',
      "3. `sessions.prompt({ sessionId, text })`",
      "4. End your turn. When the agent finishes, Codevisor sends you a `<codevisor-event>` with its result",
      ""
    ].join("\n")

    const upgraded = upgradeBotInstructions(eventBot, true)

    expect(upgraded).toContain("`machines.current.tools.codevisor.messages.send`")
    expect(upgraded).not.toContain("sessions.")
    expect(upgraded).toContain("with its complete final reply")
  })

  it("rewrite only the repository list, adding it before delegation when it is missing", () => {
    const web = { folderName: "web", name: "web", repoDir: "/src/web", projectId: "web-project" }
    const listed = [
      "## Repositories",
      "",
      "- `web/`: web (from `/src/web`, projectId `web-project`)",
      ""
    ].join("\n")

    const replaced = replaceRepositories(legacy, [web])
    const inserted = replaceRepositories(
      legacy.replace("## Repositories\n\n- `api/`: api\n\n", ""),
      [web]
    )

    expect(replaced).toContain(`You are a long-lived Codevisor bot.\n\n${listed}`)
    expect(replaced).not.toContain("- `api/`: api")
    expect(replaced).toMatch(/`bot\.projects_remove\(\{ projectId \}\)`\.\n\n## Delegating work\n/)
    expect(inserted).toBe(replaced)
    expect(replaceRepositories(replaced, [web])).toBe(replaced)
  })

  it("upgrade every bot's instructions on startup, skipping bots whose file is gone", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    await running.addProject("web-project", "web")
    const missing = decodeBot(
      (await createBot(running, { name: "Missing", projectIds: ["web-project"] })).body
    )
    const chatty = decodeBot(
      (
        await createBot(running, {
          name: "Chatty",
          projectIds: ["api-project"],
          conversational: true
        })
      ).body
    )
    const instructions = join(chatty.rootPath, "AGENTS.md")
    writeFileSync(instructions, "# Chatty\n\nYou are a long-lived Codevisor bot.\n")
    rmSync(join(missing.rootPath, "AGENTS.md"))

    await upgradeAllBotInstructions(running.services)
    const upgraded = readFileSync(instructions, "utf8")
    await upgradeAllBotInstructions(running.services)

    expect(upgraded).toMatch(/You are a long-lived Codevisor bot\.\n\n## Talking to the user/)
    expect(readFileSync(instructions, "utf8")).toBe(upgraded)
    expect(existsSync(join(missing.rootPath, "AGENTS.md"))).toBe(false)
  })
})
