import { existsSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Bot, SessionSummary } from "@codevisor/api"
import {
  ARCHIVE_RETENTION_SINCE_SETTING,
  botPath,
  makeAttachmentStore,
  makeDatabase,
  type CodevisorDatabaseService
} from "@codevisor/db"
import { Effect } from "effect"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { sweepArchives, type ArchiveRetentionDeps } from "./archive-retention.js"
import { ARCHIVE_RETENTION_SETTING_KEY } from "./infra/archive-retention-policy.js"
import { tempDirs } from "./test-support-resources.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const dayMs = 86_400_000

const archivedOn = Date.parse("2026-11-01T00:00:00.000Z")

const daysAfterArchive = (days: number): number => archivedOn + days * dayMs

const temporaryDirectory = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-archive-retention-"))
  tempDirs.push(directory)
  return directory
}

const setUp = async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  onTestFinished(() => {
    vi.useRealTimers()
  })
  vi.setSystemTime(archivedOn - 60 * dayMs)
  vi.stubEnv("CODEVISOR_WORKTREES_ROOT", temporaryDirectory())
  const directory = temporaryDirectory()
  const db = await run(
    makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "machine-a" })
  )
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: join(directory, "repo") }))
  vi.setSystemTime(archivedOn)
  const removedBots: Array<string> = []
  const deps: ArchiveRetentionDeps = {
    db,
    attachments: makeAttachmentStore(directory),
    deleteChat: (chat: SessionSummary) => run(db.deleteSession(chat.id)),
    removeBot: async (bot: Bot) => {
      removedBots.push(bot.id)
    },
    forgetUnrestorableSnapshots: async () => {}
  }
  return { db, deps, project, removedBots }
}

const chooseRetention = (db: CodevisorDatabaseService, value: string) =>
  run(
    db.mergeSyncEntries("settings", [
      {
        key: ARCHIVE_RETENTION_SETTING_KEY,
        value,
        timestamp: { wallMs: archivedOn, counter: 0, deviceId: "mac" }
      }
    ])
  )

const createChat = (db: CodevisorDatabaseService, projectId: string) =>
  run(db.createSession({ projectId, harnessId: "codex" }))

const archivedChat = async (db: CodevisorDatabaseService, projectId: string) => {
  const chat = await createChat(db, projectId)
  await run(db.archiveSession(chat.id))
  return chat
}

const storeFile = async (deps: ArchiveRetentionDeps, id: string) => {
  const stored = await deps.attachments.put(Buffer.from(`bytes of ${id}`))
  const file = await run(
    deps.db.createDiskFile({
      id,
      name: `${id}.png`,
      mimeType: "image/png",
      sizeBytes: stored.sizeBytes,
      sha256: stored.sha256,
      kind: "image",
      createdAt: new Date(archivedOn).toISOString()
    })
  )
  return { file, path: stored.path }
}

const fileExists = async (db: CodevisorDatabaseService, id: string): Promise<boolean> =>
  (await run(db.getFileMetadata(id))) !== undefined

const chatExists = async (db: CodevisorDatabaseService, id: string): Promise<boolean> =>
  (await run(db.listSessions)).some((chat) => chat.id === id)

const sendFiles = (db: CodevisorDatabaseService, chatId: string, fileIds: ReadonlyArray<string>) =>
  run(
    db.appendEvent("session.output", chatId, {
      sessionUpdate: "assistant_message_finalized",
      markdown: "Here you go",
      attachments: fileIds.map((fileId) => ({ fileId, name: `${fileId}.png` }))
    })
  )

const seedArchivedBot = async (db: CodevisorDatabaseService) => {
  const home = await run(db.createProject({ folderPath: botPath("helper"), name: "Helper" }))
  await run(
    db.createWorkspaceWithSession({
      workspace: { id: "ws-helper", projectId: home.id, name: "Helper", hasCustomName: false },
      session: { id: "chat-helper", projectId: home.id, harnessId: "codex", title: "Helper" }
    })
  )
  await run(db.archiveSession("chat-helper"))
  const bot = await run(
    db.createBot({
      id: "bot-helper",
      name: "Helper",
      symbolName: "sparkles",
      mascot: { color: "mint", hat: "none", eyewear: "none" },
      slug: "helper",
      projectId: home.id,
      sessionId: "chat-helper",
      workspaceId: "ws-helper",
      projects: []
    })
  )
  return await run(db.updateBot(bot.id, { isArchived: true }))
}

describe("archive retention", () => {
  it("deletes chats archived longer than the chosen period and keeps the rest", async () => {
    const { db, deps, project } = await setUp()
    await chooseRetention(db, "7-days")
    const archived = await archivedChat(db, project.id)
    const active = await createChat(db, project.id)

    await sweepArchives(deps, daysAfterArchive(6))
    expect(await chatExists(db, archived.id)).toBe(true)

    await sweepArchives(deps, daysAfterArchive(7))
    expect(await chatExists(db, archived.id)).toBe(false)
    expect(await chatExists(db, active.id)).toBe(true)
  })

  it("keeps archived chats for 30 days when no period was chosen", async () => {
    const { db, deps, project } = await setUp()
    const archived = await archivedChat(db, project.id)

    await sweepArchives(deps, daysAfterArchive(29))
    expect(await chatExists(db, archived.id)).toBe(true)

    await sweepArchives(deps, daysAfterArchive(30))
    expect(await chatExists(db, archived.id)).toBe(false)
  })

  it("keeps archived chats forever when the period is never", async () => {
    const { db, deps, project } = await setUp()
    await chooseRetention(db, "never")
    const archived = await archivedChat(db, project.id)

    await sweepArchives(deps, daysAfterArchive(3650))

    expect(await chatExists(db, archived.id)).toBe(true)
  })

  it("starts the clock for chats archived before the upgrade at the upgrade", async () => {
    const { db, deps, project } = await setUp()
    const archived = await archivedChat(db, project.id)
    const upgradedAt = new Date(daysAfterArchive(100)).toISOString()
    await run(db.setMachineSetting(ARCHIVE_RETENTION_SINCE_SETTING, upgradedAt))

    await sweepArchives(deps, daysAfterArchive(129))
    expect(await chatExists(db, archived.id)).toBe(true)

    await sweepArchives(deps, daysAfterArchive(130))
    expect(await chatExists(db, archived.id)).toBe(false)
  })

  it("removes the stored bytes of the attachments only expired chats used", async () => {
    const { db, deps, project } = await setUp()
    const archived = await archivedChat(db, project.id)
    const active = await createChat(db, project.id)
    const own = await storeFile(deps, "own")
    const kept = await storeFile(deps, "kept")
    await sendFiles(db, archived.id, [own.file.id])
    await sendFiles(db, active.id, [kept.file.id])

    await sweepArchives(deps, daysAfterArchive(30))

    expect(await fileExists(db, own.file.id)).toBe(false)
    expect(existsSync(own.path)).toBe(false)
    expect(await fileExists(db, kept.file.id)).toBe(true)
    expect(existsSync(kept.path)).toBe(true)
  })

  it("deletes files no chat has used for the chosen period, except ones waiting to be sent", async () => {
    const { db, deps, project } = await setUp()
    const chat = await createChat(db, project.id)
    const abandoned = await storeFile(deps, "abandoned")
    const queued = await storeFile(deps, "queued")
    await run(
      db.createPromptQueueItem(chat.id, "look at this", [
        {
          fileId: queued.file.id,
          name: "queued.png",
          mimeType: "image/png",
          sizeBytes: queued.file.sizeBytes,
          kind: "image"
        }
      ])
    )

    await sweepArchives(deps, daysAfterArchive(29))
    expect(await fileExists(db, abandoned.file.id)).toBe(true)

    await sweepArchives(deps, daysAfterArchive(30))
    expect(await fileExists(db, abandoned.file.id)).toBe(false)
    expect(existsSync(abandoned.path)).toBe(false)
    expect(await fileExists(db, queued.file.id)).toBe(true)
  })

  it("removes an expired archived bot and leaves its chat to the bot's removal", async () => {
    const { db, deps, removedBots } = await setUp()
    const bot = await seedArchivedBot(db)

    await sweepArchives(deps, daysAfterArchive(30))

    expect(removedBots).toEqual([bot.id])
    expect(await chatExists(db, bot.sessionId)).toBe(true)
  })
})
