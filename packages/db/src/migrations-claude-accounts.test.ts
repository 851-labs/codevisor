import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const chatId = "00000000-0000-4000-8000-000000000001"

const open = async (filename: string): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const account = (harnessId: string, profileKind: "default" | "managed") => ({
  harnessId,
  profileKind,
  ...(profileKind === "managed" ? { profileKey: `${harnessId}-managed` } : {}),
  label: `${harnessId} ${profileKind}`,
  authState: "authenticated" as const,
  canLogin: true,
  canLogout: false
})

const seedV104 = async (filename: string) => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  const claudeDefault = await run(db.saveHarnessAccount(account("claude-code", "default")))
  await run(db.saveHarnessAccount(account("claude-code", "managed")))
  await run(db.saveHarnessAccount(account("codex", "default")))
  const project = await run(db.createProject({ folderPath: "/tmp/claude-repo", name: "repo" }))
  await run(
    db.createWorkspaceWithSession({
      workspace: { id: "ws-chat", projectId: project.id, name: "chat", hasCustomName: false },
      session: { id: chatId, projectId: project.id, harnessId: "claude-code", title: "chat" }
    })
  )
  await run(db.bindSessionHarnessAccount(chatId, claudeDefault.id))
  await run(db.close)
  const sqlite = new Database(filename)
  try {
    sqlite.exec("delete from schema_migrations where id = 105")
  } finally {
    sqlite.close()
  }
}

describe("claude default account removal", () => {
  it("retires Claude's machine profile and unbinds its chats, leaving other harnesses alone", async () => {
    const filename = tempDatabase()
    await seedV104(filename)

    const db = await open(filename)

    expect(await run(db.listHarnessAccounts("claude-code"))).toMatchObject([
      { profileKind: "managed", isActive: false }
    ])
    expect(await run(db.listHarnessAccounts("codex"))).toMatchObject([
      { profileKind: "default", isActive: true }
    ])
    expect((await run(db.getSessionSummary(chatId))).harnessAccountId).toBeUndefined()
  })
})
