import type { Harness } from "@herdman/api"
import Database from "better-sqlite3"
import { Effect } from "effect"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { DatabaseError, HerdManDatabase, makeDatabase } from "./index.js"

const tempDirs: Array<string> = []

const tempDatabase = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "herdman-db-"))
  tempDirs.push(dir)
  return join(dir, "herdman.sqlite")
}

const run = <A>(effect: Effect.Effect<A, DatabaseError>): Promise<A> => Effect.runPromise(effect)

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { force: true, recursive: true })
  }
})

describe("@herdman/db", () => {
  it("migrates once and persists workspaces, sessions, conversation, and events", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))

    expect(await run(db.migrate)).toEqual([])

    const firstWorkspace = await run(db.createWorkspace({ folderPath: "/tmp/herdman" }))
    const secondWorkspace = await run(
      db.createWorkspace({ folderPath: "/tmp/named", name: "Named Workspace" })
    )
    const emptyWorkspace = await run(db.createWorkspace({ folderPath: "" }))
    const clientWorkspace = await run(
      db.createWorkspace({
        id: "workspace-client-id",
        folderPath: "/tmp/client",
        name: "Client Workspace",
        isArchived: true,
        symbolName: "externaldrive",
        origin: "imported",
        createdAt: "2026-06-30T00:00:00.000Z"
      })
    )
    expect(firstWorkspace.name).toBe("herdman")
    expect(secondWorkspace.name).toBe("Named Workspace")
    expect(emptyWorkspace.name).toBe("")
    expect(clientWorkspace).toEqual({
      id: "workspace-client-id",
      name: "Client Workspace",
      folderPath: "/tmp/client",
      isArchived: true,
      symbolName: "externaldrive",
      origin: "imported",
      createdAt: "2026-06-30T00:00:00.000Z"
    })

    const updatedWorkspace = await run(
      db.updateWorkspace(firstWorkspace.id, {
        isArchived: true,
        name: "Archived HerdMan",
        symbolName: "archivebox"
      })
    )
    expect(updatedWorkspace).toMatchObject({
      isArchived: true,
      name: "Archived HerdMan",
      symbolName: "archivebox"
    })
    expect(await run(db.updateWorkspace(secondWorkspace.id, {}))).toMatchObject({
      isArchived: false,
      name: "Named Workspace",
      symbolName: "folder"
    })
    await expect(run(db.updateWorkspace("missing", { name: "nope" }))).rejects.toBeInstanceOf(
      DatabaseError
    )

    const firstSession = await run(
      db.createSession({
        workspaceId: firstWorkspace.id,
        harnessId: "codex",
        agentSessionId: "agent-1"
      })
    )
    const secondSession = await run(
      db.createSession({
        workspaceId: secondWorkspace.id,
        harnessId: "claude-code",
        title: "Explicit title"
      })
    )
    const clientSession = await run(
      db.createSession({
        id: "session-client-id",
        workspaceId: clientWorkspace.id,
        harnessId: "codex",
        agentSessionId: "agent-client-id",
        title: "Client Session",
        origin: "imported",
        isArchived: true,
        createdAt: "2026-06-30T00:00:00.000Z",
        updatedAt: "2026-06-30T00:01:00.000Z"
      })
    )
    expect(firstSession.title).toBe("New Session")
    expect(firstSession.agentSessionId).toBe("agent-1")
    expect(secondSession.title).toBe("Explicit title")
    expect(clientSession).toMatchObject({
      agentSessionId: "agent-client-id",
      id: "session-client-id",
      isArchived: true,
      origin: "imported",
      title: "Client Session",
      updatedAt: "2026-06-30T00:01:00.000Z"
    })
    expect(await run(db.updateSession(secondSession.id, {}))).toMatchObject({
      isArchived: false,
      title: "Explicit title"
    })
    expect(
      await run(db.updateSession(secondSession.id, { agentSessionId: "agent-2" }))
    ).toMatchObject({
      agentSessionId: "agent-2",
      title: "Explicit title"
    })

    const renamedSession = await run(
      db.updateSession(firstSession.id, { isArchived: true, title: "Renamed session" })
    )
    expect(renamedSession).toMatchObject({
      isArchived: true,
      title: "Renamed session"
    })

    await run(db.appendConversationItem(firstSession.id, "user", "user-1", "hello", false))
    await run(
      db.appendConversationItem(firstSession.id, "assistant", "assistant-1", "streaming", true)
    )
    await run(db.appendConversationItem(firstSession.id, "assistant", undefined, "no id", false))
    const detail = await run(db.getSessionDetail(firstSession.id))
    expect(detail.eventCursor).toBe(0)
    expect(
      detail.conversation.map((item) => [item.role, item.messageId, item.text, item.isGenerating])
    ).toEqual([
      ["user", "user-1", "hello", false],
      ["assistant", "assistant-1", "streaming", true],
      ["assistant", undefined, "no id", false]
    ])

    const event = await run(
      db.appendEvent("session.output", firstSession.id, { text: "chunk", index: 1 })
    )
    expect(event.id).toBe(1)
    expect(await run(db.listEvents(0))).toMatchObject([
      { id: 1, kind: "session.output", payload: { text: "chunk", index: 1 } }
    ])
    expect(await run(db.listEvents(1))).toEqual([])
    expect((await run(db.getSessionDetail(firstSession.id))).eventCursor).toBe(1)

    expect(await run(db.getSessionActionResult(firstSession.id, "prompt-1"))).toBeUndefined()
    await run(
      db.saveSessionActionResult(firstSession.id, "prompt-1", "prompt", {
        stopReason: "end_turn"
      })
    )
    await run(
      db.saveSessionActionResult(firstSession.id, "prompt-1", "prompt", {
        stopReason: "duplicate_should_not_replace"
      })
    )
    expect(await run(db.getSessionActionResult(firstSession.id, "prompt-1"))).toEqual({
      stopReason: "end_turn"
    })

    const queuedA = await run(db.createPromptQueueItem(firstSession.id, "queued a"))
    const queuedB = await run(db.createPromptQueueItem(firstSession.id, "queued b"))
    expect(
      (await run(db.getSessionDetail(firstSession.id))).promptQueue.map((item) => item.text)
    ).toEqual(["queued a", "queued b"])
    expect(
      await run(db.updatePromptQueueItem(firstSession.id, queuedB.id, "queued b edited"))
    ).toMatchObject({ text: "queued b edited" })
    expect(await run(db.shiftPromptQueueItem(firstSession.id))).toMatchObject({
      id: queuedA.id,
      text: "queued a"
    })
    await run(db.deletePromptQueueItem(firstSession.id, queuedB.id))
    expect(await run(db.listPromptQueue(firstSession.id))).toEqual([])
    await expect(
      run(db.updatePromptQueueItem(firstSession.id, "missing-queue-item", "nope"))
    ).rejects.toBeInstanceOf(DatabaseError)
    await expect(
      run(db.deletePromptQueueItem(firstSession.id, "missing-queue-item"))
    ).rejects.toBeInstanceOf(DatabaseError)
    expect(await run(db.shiftPromptQueueItem(firstSession.id))).toBeUndefined()

    const sqlite = new Database(filename)
    sqlite
      .prepare(
        "update sessions set usage_used = 12, usage_size = 120, cost_amount = 0.42, cost_currency = 'USD' where id = ?"
      )
      .run(firstSession.id)
    sqlite.close()
    expect((await run(db.getSessionDetail(firstSession.id))).session.usage).toEqual({
      costAmount: 0.42,
      costCurrency: "USD",
      size: 120,
      used: 12
    })

    expect((await run(db.listSessions)).map((session) => session.id)).toContain(firstSession.id)
    expect((await run(db.listWorkspaces)).map((workspace) => workspace.id)).toContain(
      secondWorkspace.id
    )

    expect((await run(db.archiveSession(firstSession.id))).isArchived).toBe(true)
    await expect(run(db.updateSession("missing", { title: "Missing" }))).rejects.toBeInstanceOf(
      DatabaseError
    )
    await expect(run(db.archiveSession("missing"))).rejects.toBeInstanceOf(DatabaseError)
    await run(db.deleteSession(secondSession.id))
    await expect(run(db.getSessionDetail(secondSession.id))).rejects.toBeInstanceOf(DatabaseError)
    await run(db.deleteWorkspace(clientWorkspace.id))
    await expect(run(db.getSessionDetail(clientSession.id))).rejects.toBeInstanceOf(DatabaseError)
    await expect(run(db.deleteWorkspace("missing"))).rejects.toBeInstanceOf(DatabaseError)

    await Effect.runPromise(db.close)
  })

  it("applies harness settings, auth tokens, and update state", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "server-a" }))
    const harnesses: ReadonlyArray<Harness> = [
      {
        id: "codex",
        name: "Codex",
        symbolName: "chevron.left.forwardslash.chevron.right",
        source: "registry",
        launchKind: "npx",
        enabled: true,
        readiness: { state: "ready" }
      },
      {
        id: "claude-code",
        name: "Claude Code",
        symbolName: "sparkle",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: { state: "unavailable", detail: "missing" }
      }
    ]

    expect(await run(db.applyHarnessSettings(harnesses))).toEqual(harnesses)
    await run(db.setHarnessEnabled("codex", false))
    expect(
      (await run(db.applyHarnessSettings(harnesses))).map((harness) => harness.enabled)
    ).toEqual([false, true])
    await run(db.setHarnessEnabled("codex", true))
    expect(
      (await run(db.applyHarnessSettings(harnesses))).map((harness) => harness.enabled)
    ).toEqual([true, true])

    const token = await run(db.issuePairingToken)
    expect(token.startsWith("hm_")).toBe(true)
    expect(await run(db.verifyBearerToken(token))).toBe(true)
    expect(await run(db.verifyBearerToken("hm_wrong"))).toBe(false)

    expect(await run(db.getUpdateInfo)).toMatchObject({
      currentVersion: "0.1.0",
      updateAvailable: false,
      migrationState: "idle"
    })
    const update = await run(
      db.setUpdateInfo({
        currentVersion: "0.1.0",
        latestVersion: "0.2.0",
        updateAvailable: true,
        channel: "development",
        checkedAt: "2026-06-30T01:00:00.000Z",
        migrationState: "running"
      })
    )
    expect(update.updateAvailable).toBe(true)
    expect(await run(db.getUpdateInfo)).toEqual(update)
    expect(
      await run(
        db.setUpdateInfo({
          currentVersion: "0.2.0",
          latestVersion: "0.2.0",
          updateAvailable: false,
          channel: "stable",
          migrationState: "idle"
        })
      )
    ).toEqual({
      currentVersion: "0.2.0",
      latestVersion: "0.2.0",
      updateAvailable: false,
      channel: "stable",
      migrationState: "idle"
    })

    await Effect.runPromise(db.close)
  })

  it("constructs the Effect service layer", async () => {
    const info = await Effect.runPromise(
      Effect.gen(function* () {
        const db = yield* HerdManDatabase
        const update = yield* db.getUpdateInfo
        yield* db.close
        return update
      }).pipe(
        Effect.provide(
          HerdManDatabase.layer({
            filename: tempDatabase(),
            serverId: "layered"
          })
        )
      )
    )

    expect(info.currentVersion).toBe("0.1.0")
  })

  it("surfaces sqlite errors as tagged database errors", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    await run(db.createWorkspace({ folderPath: "/tmp/duplicate" }))
    const failed = await Effect.runPromiseExit(db.createWorkspace({ folderPath: "/tmp/duplicate" }))
    expect(String(failed)).toContain("DatabaseError")
    await Effect.runPromise(db.close)
  })
})
