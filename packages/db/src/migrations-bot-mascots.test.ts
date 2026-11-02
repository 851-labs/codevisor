import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { botPath, makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { rewindBotMascotsSql, run, tempDatabase } from "./test-support.js"

const useWorktreesRoot = (): void => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-bot-mascots-"))
  const previous = process.env["CODEVISOR_WORKTREES_ROOT"]
  process.env["CODEVISOR_WORKTREES_ROOT"] = root
  onTestFinished(() => {
    if (previous === undefined) delete process.env["CODEVISOR_WORKTREES_ROOT"]
    else process.env["CODEVISOR_WORKTREES_ROOT"] = previous
    rmSync(root, { force: true, recursive: true })
  })
}

const seedBot = async (db: CodevisorDatabaseService, slug: string): Promise<void> => {
  const home = await run(db.createProject({ folderPath: botPath(slug), name: slug }))
  await run(
    db.createWorkspaceWithSession({
      workspace: { id: `ws-${slug}`, projectId: home.id, name: slug, hasCustomName: false },
      session: { id: `chat-${slug}`, projectId: home.id, harnessId: "codex", title: slug }
    })
  )
  await run(
    db.createBot({
      id: `bot-${slug}`,
      name: slug,
      symbolName: "ant",
      mascot: { color: "dream", hat: "crown", eyewear: "specs" },
      slug,
      projectId: home.id,
      sessionId: `chat-${slug}`,
      workspaceId: `ws-${slug}`,
      projects: []
    })
  )
}

describe("bot mascot upgrade", () => {
  it("gives each existing bot a plain mascot, colored in creation order", async () => {
    useWorktreesRoot()
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
    for (const slug of ["first", "second", "third"]) await seedBot(db, slug)
    await run(db.close)
    const sqlite = new Database(filename)
    try {
      sqlite.exec(rewindBotMascotsSql)
    } finally {
      sqlite.close()
    }

    const upgraded = await run(makeDatabase({ filename, serverId: "machine-a" }))
    onTestFinished(() => run(upgraded.close))

    expect(
      (await run(upgraded.listBots)).map((bot) => [bot.id, bot.symbolName, bot.mascot])
    ).toEqual([
      ["bot-first", "ant", { color: "sunny", hat: "none", eyewear: "none" }],
      ["bot-second", "ant", { color: "mint", hat: "none", eyewear: "none" }],
      ["bot-third", "ant", { color: "lilac", hat: "none", eyewear: "none" }]
    ])
  })
})
