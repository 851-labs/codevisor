import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { jsonRequest, run, startWithApp, waitFor } from "../test-support.js"
import { codevisorBlock, type BotInstructionsSubject } from "./bot-instructions-text.js"
import { instructionsWithBlock } from "./bot-instructions.js"
import { createBot, decodeBot, setUp } from "./bot-test-support.js"

const workBot: BotInstructionsSubject = {
  name: "Work Bot",
  repositories: [{ folderName: "api", name: "api", repoDir: "/src/api", projectId: "api-project" }]
}

const oldFile = (custom: {
  readonly intro: string
  readonly repositoryLine: string
  readonly section: string
}) =>
  [
    "# Work Bot",
    "",
    "You are a long-lived Codevisor bot that coordinates work across the repositories below.",
    "Plan the work, hand it to sub-agents, and follow up on their results. Don't change code",
    "yourself; read the folders below to understand the code and decide what to delegate.",
    "",
    custom.intro,
    "",
    "## Talking to the user",
    "",
    "The user chats with you like iMessage and only sees the messages you send with",
    "`codevisor.messages.send` through the Codevisor MCP. Nothing else you write reaches them, not",
    "even your final reply. Read the `codevisor-messages` skill before your first reply.",
    "",
    "## Repositories",
    "",
    "- `api/`: api (from `/src/api`, projectId `api-project`)",
    custom.repositoryLine,
    "",
    "When a task needs a repository that isn't listed, add it with",
    "`bot.projects_add({ projectId })`, using a projectId from `projects.list`. Remove one you no",
    "longer need with `bot.projects_remove({ projectId })`.",
    "",
    "## Delegating work",
    "",
    "Give each task to a sub-agent in a workspace of its own with the Codevisor MCP, on an",
    "isolated worktree of the repository it changes. Use the projectId above; this folder is",
    "not a project you can branch from.",
    "",
    "1. `worktrees.create({ projectId })`",
    '2. `sessions.create({ projectId, worktreeName, harnessId: "codex", title })`',
    "3. `sessions.prompt({ sessionId, text })`",
    "4. End your turn. When the agent finishes, Codevisor sends you a `<codevisor-event>` with its result",
    "",
    "Workspaces your sub-agents work in, and any they create, are listed under this bot in the",
    "Codevisor sidebar.",
    "",
    custom.section,
    ""
  ].join("\n")

const file = (rootPath: string) => join(rootPath, "AGENTS.md")

const custom = {
  intro: "Reply in Spanish.",
  repositoryLine: "- `scratch/`: my own scratch notes",
  section: "## Release checklist\n\n1. Bump the version\n2. Tag the release"
}

describe("bot instructions", () => {
  it("move a bot's own text from an old file under Notes, below Codevisor's block", () => {
    const migrated = instructionsWithBlock(oldFile(custom), workBot)

    expect(migrated).toBe(
      [
        codevisorBlock(workBot),
        "## Notes",
        "Reply in Spanish.",
        "- `scratch/`: my own scratch notes",
        "## Release checklist",
        "1. Bump the version\n2. Tag the release\n"
      ].join("\n\n")
    )
    expect(instructionsWithBlock(migrated, workBot)).toBe(migrated)
  })

  it("replace only the marked block, keeping everything around it", () => {
    const renamed = { ...workBot, name: "Release Bot" }
    const text = `Pinned above.\n\n${codevisorBlock(workBot)}\n\n## Notes\n\nShip on Fridays.\n`

    const updated = instructionsWithBlock(text, renamed)

    expect(updated).toBe(
      `Pinned above.\n\n${codevisorBlock(renamed)}\n\n## Notes\n\nShip on Fridays.\n`
    )
  })

  it("rebuild a block whose markers were deleted without duplicating it into Notes", () => {
    const unmarked = codevisorBlock(workBot)
      .replace("<!-- codevisor:begin -->", "")
      .replace("<!-- codevisor:end -->", "")

    const rebuilt = instructionsWithBlock(`${unmarked}\n\n## Notes\n\nShip on Fridays.\n`, workBot)

    expect(rebuilt).toBe(`${codevisorBlock(workBot)}\n\n## Notes\n\nShip on Fridays.\n`)
  })

  it("bring every bot's file up to date when the server starts, and tell the bots it changed", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = async (name: string) =>
      decodeBot((await createBot(running, { name, projectIds: ["api-project"] })).body)
    const [current, outdated, archived, missing] = [
      await bot("Current"),
      await bot("Outdated"),
      await bot("Archived"),
      await bot("Missing")
    ]
    await jsonRequest(running.server, `/v1/bots/${archived.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    const untouched = readFileSync(file(current.rootPath), "utf8")
    for (const old of [outdated, archived]) {
      writeFileSync(file(old.rootPath), `# ${old.name}\n\nReply in Spanish.\n`)
    }
    rmSync(file(missing.rootPath))
    const told = () =>
      running.agents.prompts.filter(([, input]) =>
        JSON.stringify(input).includes("bot.instructions_updated")
      )

    const restarted = await startWithApp(running.services)
    onTestFinished(() => run(restarted.close))
    await waitFor(() => told().length === 1)

    expect(readFileSync(file(current.rootPath), "utf8")).toBe(untouched)
    for (const old of [outdated, archived]) {
      const text = readFileSync(file(old.rootPath), "utf8")
      expect(text).toContain(`<!-- codevisor:begin -->\n\n# ${old.name}\n`)
      expect(text.endsWith("## Notes\n\nReply in Spanish.\n")).toBe(true)
    }
    expect(existsSync(file(missing.rootPath))).toBe(false)
    expect(JSON.stringify(told()[0])).toContain("Reread the file before your next reply")
  })
})
