import type { AttachmentRef, FileMetadata } from "@codevisor/api"
import Database from "better-sqlite3"
import { Effect } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const ref = (file: FileMetadata): AttachmentRef => ({
  fileId: file.id,
  name: file.name,
  mimeType: file.mimeType,
  sizeBytes: file.sizeBytes,
  kind: file.kind
})

const executeUpdate = (files: ReadonlyArray<Record<string, unknown>>) => ({
  sessionUpdate: "tool_call_update",
  toolCallId: "execute-tool",
  title: "mcp__codevisor__execute",
  status: "completed",
  _meta: {
    codevisorExecution: {
      state: "completed",
      calls: [
        { path: "browser.open", ok: true, ms: 4 },
        { path: "browser.screenshot", ok: true, ms: 12, files }
      ]
    }
  }
})

let clock = 0
const tick = () => vi.setSystemTime(new Date(Date.UTC(2026, 9, 15, 12, 0, ++clock)))

beforeEach(() => {
  clock = 0
  vi.useFakeTimers({ toFake: ["Date"] })
})

afterEach(() => {
  vi.useRealTimers()
})

const seedWorkspace = async (db: CodevisorDatabaseService, name: string) => {
  const project = await run(db.createProject({ folderPath: `/tmp/workspace-media-${name}` }))
  const workspace = await run(
    db.upsertWorkspace({ projectId: project.id, name, hasCustomName: false })
  )
  const session = async () => {
    const created = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.setSessionWorkspace(created.id, workspace.id))
    return created
  }
  return { workspace, session }
}

describe("workspace media", () => {
  it("lists a workspace's chat images newest first, deduplicated by content, and paged", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const work = await seedWorkspace(db, "work")
      const other = await seedWorkspace(db, "other")
      const first = await work.session()
      const second = await work.session()
      const elsewhere = await other.session()
      const image = (name: string, bytes: string) =>
        run(db.createFile(name, "image/png", "image", Buffer.from(bytes)))
      const typed = (name: string, mimeType: string) =>
        run(db.createFile(name, mimeType, "file", Buffer.from(name)))
      const attached = await image("attached.png", "attached")
      const document = await typed("notes.pdf", "application/pdf")
      const screenshot = await image("screenshot.png", "screenshot")
      const recording = await typed("recording.mp4", "video/mp4")
      const generated = await image("generated.png", "generated")
      const copy = await image("copy.png", "attached")
      const foreign = await image("foreign.png", "foreign")

      tick()
      await run(
        db.appendEvent("session.output", first.id, {
          role: "user",
          text: "Look at https://example.com/first",
          attachments: [ref(attached), ref(document)]
        })
      )
      tick()
      await run(db.appendEvent("session.updated", first.id, { turnState: "started" }))
      const execution = executeUpdate([
        { fileId: screenshot.id, mimeType: "image/png" },
        { fileId: recording.id, mimeType: "video/mp4" },
        { fileId: "missing-file", mimeType: "image/png" },
        { name: "unsaved.png" }
      ])
      await run(db.appendEvent("session.output", first.id, execution))
      await run(db.appendEvent("session.output", first.id, execution))
      tick()
      await run(db.appendEvent("session.updated", second.id, { turnState: "started" }))
      await run(
        db.appendEvent("session.output", second.id, {
          sessionUpdate: "tool_call_update",
          kind: "image_generation",
          toolCallId: "image-tool",
          status: "completed",
          rawOutput: { attachment: ref(generated) }
        })
      )
      tick()
      await run(
        db.appendEvent("session.output", second.id, {
          sessionUpdate: "tool_call_update",
          toolCallId: "read-tool",
          status: "completed",
          toolImages: [ref(copy)]
        })
      )
      tick()
      await run(
        db.appendEvent("session.output", first.id, {
          sessionUpdate: "assistant_message_finalized",
          markdown: "Done, see [the docs](https://example.com/docs).",
          attachments: []
        })
      )
      await run(
        db.appendEvent("session.output", elsewhere.id, {
          role: "user",
          text: "https://elsewhere.example.com",
          attachments: [ref(foreign)]
        })
      )

      const photos = await run(db.listWorkspacePhotos(work.workspace.id, undefined, 10))
      expect(photos.map((photo) => [photo.attachment.fileId, photo.source])).toEqual([
        [copy.id, "tool"],
        [generated.id, "message"],
        [screenshot.id, "tool"]
      ])
      expect(photos[0]).toMatchObject({ sessionId: second.id, attachment: ref(copy) })

      const page = await run(db.listWorkspacePhotos(work.workspace.id, undefined, 2))
      const last = page.at(-1)!
      expect(
        await run(
          db.listWorkspacePhotos(
            work.workspace.id.toUpperCase(),
            { createdAt: last.createdAt, id: last.attachment.fileId },
            2
          )
        )
      ).toEqual([photos[2]])

      const texts = await run(db.listWorkspaceMessageTexts(work.workspace.id, undefined, 10))
      expect(texts.map((message) => [message.sessionId, message.text])).toEqual([
        [first.id, "Done, see [the docs](https://example.com/docs)."],
        [first.id, "Look at https://example.com/first"]
      ])
      const newest = texts[0]!
      expect(
        await run(
          db.listWorkspaceMessageTexts(
            work.workspace.id,
            { createdAt: newest.createdAt, id: newest.itemId },
            10
          )
        )
      ).toEqual([texts[1]])
    } finally {
      await run(db.close)
    }
  })

  it("backfills execution screenshots recorded before tool media was tracked", async () => {
    const filename = tempDatabase()
    const current = await run(makeDatabase({ filename, serverId: "local" }))
    const work = await seedWorkspace(current, "upgrade")
    const session = await work.session()
    const screenshot = await run(
      current.createFile("screenshot.png", "image/png", "image", Buffer.from("upgrade"))
    )
    tick()
    await run(current.appendEvent("session.updated", session.id, { turnState: "started" }))
    await run(
      current.appendEvent(
        "session.output",
        session.id,
        executeUpdate([{ fileId: screenshot.id, mimeType: "image/png" }])
      )
    )
    await Effect.runPromise(current.close)

    const legacy = new Database(filename)
    legacy.exec(`
      drop table chat_item_media;
      delete from schema_migrations where id = 62;
    `)
    legacy.close()

    const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect(
        await run(upgraded.listWorkspacePhotos(work.workspace.id, undefined, 10))
      ).toMatchObject([{ attachment: ref(screenshot), sessionId: session.id, source: "tool" }])
    } finally {
      await run(upgraded.close)
    }
  })
})
