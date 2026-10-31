import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { botPath, makeDatabase } from "./index.js"
import { rewindBotModesSql, run, tempDatabase } from "./test-support.js"

const useWorktreesRoot = (): void => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-bot-modes-"))
  const previous = process.env["CODEVISOR_WORKTREES_ROOT"]
  process.env["CODEVISOR_WORKTREES_ROOT"] = root
  onTestFinished(() => {
    if (previous === undefined) delete process.env["CODEVISOR_WORKTREES_ROOT"]
    else process.env["CODEVISOR_WORKTREES_ROOT"] = previous
    rmSync(root, { force: true, recursive: true })
  })
}

describe("bot display mode upgrade", () => {
  it("gives conversational bots the conversation mode and every other bot the transcript mode", async () => {
    useWorktreesRoot()
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
    for (const [slug, mode] of [
      ["chatty", "conversation"],
      ["quiet", "bubbles"]
    ] as const) {
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
          symbolName: "sparkles",
          slug,
          projectId: home.id,
          sessionId: `chat-${slug}`,
          workspaceId: `ws-${slug}`,
          mode,
          projects: []
        })
      )
    }
    await run(db.close)
    const sqlite = new Database(filename)
    try {
      sqlite.exec(rewindBotModesSql)
    } finally {
      sqlite.close()
    }

    const upgraded = await run(makeDatabase({ filename, serverId: "machine-a" }))
    onTestFinished(() => run(upgraded.close))

    expect(
      (await run(upgraded.listBots)).map((bot) => [bot.id, bot.mode, bot.conversational])
    ).toEqual([
      ["bot-chatty", "conversation", true],
      ["bot-quiet", "transcript", false]
    ])
  })
})
