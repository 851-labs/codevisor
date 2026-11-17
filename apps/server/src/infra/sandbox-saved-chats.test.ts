import { FLEET_SANDBOX_CHATS_PATH, type FileMetadata } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { RECAPPED_CHAT_NOTE } from "./sandbox-saved-chats.js"
import { sandboxHarness } from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Spike box" }
const megabyte = 1024 * 1024

const session = {
  id: "chat-1",
  title: "Fix the flake",
  harnessId: "codex",
  agentSessionId: "agent-1",
  createdAt: "2026-10-22T00:00:00.000Z"
}
const pane = {
  id: "pane-1",
  providerId: "codevisor",
  paneType: "chat",
  title: "Fix the flake",
  resourceKind: "session",
  resourceId: "chat-1",
  createdAt: "2026-10-22T00:00:00.000Z"
}
const itemOf = (id: string) => ({ item: { id, role: "user" }, children: { chat_parts: [] } })

const attachment = (id: string, megabytes: number): FileMetadata => ({
  id,
  name: `${id}.png`,
  mimeType: "image/png",
  sizeBytes: megabytes * megabyte,
  sha256: id,
  kind: "image",
  createdAt: "2026-10-22T00:00:00.000Z"
})
const note: FileMetadata = { ...attachment("note", 0), name: "note.txt", sizeBytes: 5 }

const hello = Buffer.from("hello").toString("base64")

interface FakeChats {
  readonly files?: ReadonlyArray<FileMetadata>
  readonly itemIds?: ReadonlyArray<string>
  readonly listFails?: string
  readonly refusesRestore?: string
}

const sandboxWithChats =
  (chats: FakeChats = {}) =>
  (tool: string, args: Record<string, unknown>): unknown => {
    const { files = [note], itemIds = ["item-1", "item-2"] } = chats
    const { listFails, refusesRestore } = chats
    if (tool !== FLEET_SANDBOX_CHATS_PATH) return undefined
    const { action } = args
    if (action === "list" && listFails !== undefined) throw new Error(listFails)
    if (action === "list") {
      const chat = { session, itemIds, files }
      return { format: 1, chats: [chat], panes: [pane] }
    }
    if (action === "item") return itemOf(String(args["itemId"]))
    if (action === "file") return { data: hello }
    if (action === "restore_chat" && refusesRestore !== undefined) throw new Error(refusesRestore)
    return { restored: true }
  }

const archived = async (chats: FakeChats = {}) => {
  const harness = await sandboxHarness()
  harness.controls.answer = sandboxWithChats(chats)
  await harness.machines.create(request)
  await harness.machines.settled()
  const workspace = harness.workspaces[0]
  if (workspace === undefined) throw new Error("No workspace was placed")
  workspace.isArchived = true
  await harness.machines.watch()
  return harness
}

type Harness = Awaited<ReturnType<typeof archived>>

const restored = async (harness: Harness) => {
  const before = harness.toolCalls.length
  await harness.machines.restore("id-2")
  await harness.machines.settled()
  const [machine] = await harness.machines.list()
  if (machine === undefined) throw new Error("No sandbox was restored")
  const lines = (await harness.machines.log(machine.id)).map((log) => log.line)
  const putBack = harness.toolCalls
    .slice(before)
    .filter((call) => call.tool === FLEET_SANDBOX_CHATS_PATH)
    .map((call) => call.args)
  return { machine, lines, putBack }
}

describe("a sandbox's chats across archive and restore", () => {
  it("are saved on this Mac at archive and put back in the restored workspace", async () => {
    const harness = await archived()
    const archive = await harness.machines.list()
    const kept = await harness.deps.savedChats.manifest("id-2")

    const { machine, lines, putBack } = await restored(harness)

    expect(archive).toMatchObject([{ state: "archived", hasSavedChats: true }])
    expect(kept).toEqual({
      format: 1,
      chats: [{ session, files: [note] }],
      panes: [pane],
      leftOut: []
    })
    expect(machine).toMatchObject({ state: "ready", workspaceId: "id-2" })
    expect(putBack).toEqual([
      { action: "restore_chat", format: 1, workspaceId: "id-2", session },
      { action: "restore_item", format: 1, sessionId: "chat-1", item: itemOf("item-1") },
      { action: "restore_item", format: 1, sessionId: "chat-1", item: itemOf("item-2") },
      {
        action: "restore_file",
        file: note,
        offset: 0,
        data: Buffer.from("hello").toString("base64")
      },
      {
        action: "finish_chat",
        format: 1,
        sessionId: "chat-1",
        fileIds: ["note"],
        note: RECAPPED_CHAT_NOTE,
        agentSessionId: "agent-1"
      },
      { action: "restore_pane", format: 1, workspaceId: "id-2", pane }
    ])
    expect(lines).toContain("Brought back 1 chat with its history")
    expect(await harness.deps.savedChats.manifest("id-2")).toBeUndefined()
  })

  it("leaves out attachments past the caps and names each one when restoring", async () => {
    const eight = Array.from({ length: 8 }, (_, index) =>
      attachment(`shot-${String(index + 1)}`, 24)
    )
    const files = [attachment("recording", 26), ...eight, attachment("shot-9", 24), note]
    const tooBig =
      "Left out the attachment recording.png (26 MB) from the chat Fix the flake: it is over the 25 MB kept per attachment"
    const pastTotal =
      "Left out the attachment shot-9.png (24 MB) from the chat Fix the flake: this sandbox's attachments passed the 200 MB kept per sandbox"
    const harness = await archived({ files })
    const kept = await harness.deps.savedChats.manifest("id-2")

    const { lines, putBack } = await restored(harness)

    expect(kept?.leftOut).toEqual([tooBig, pastTotal])
    expect(kept?.chats[0]?.files.map((file) => file.id)).toEqual([
      ...eight.map((file) => file.id),
      "note"
    ])
    expect(harness.logs).toContain(`Sandbox Spike box (id-1): ${tooBig}`)
    expect(lines).toEqual(expect.arrayContaining([tooBig, pastTotal]))
    expect(putBack.at(-2)).toMatchObject({
      action: "finish_chat",
      fileIds: [...eight.map((file) => file.id), "note"],
      note: `${RECAPPED_CHAT_NOTE} Too large to keep: recording.png (26 MB), shot-9.png (24 MB).`
    })
  })

  it("restores without chats and says why when they couldn't be saved", async () => {
    const harness = await archived({ listFails: "Unknown tool: fleet.sandbox_chats" })
    const reason =
      "Its chats couldn't be saved when it was archived: Unknown tool: fleet.sandbox_chats"
    const archive = await harness.machines.list()

    const { machine, lines, putBack } = await restored(harness)

    expect(archive).toMatchObject([{ state: "archived", chatsLost: reason }])
    expect(harness.logs).toContain(`Sandbox Spike box (id-1): ${reason}`)
    expect(machine.state).toBe("ready")
    expect(lines).toContain(`Its earlier chats weren't kept. ${reason}`)
    expect(putBack).toEqual([])
  })

  it("archives the sandbox again with its saved chats when the new sandbox refuses them", async () => {
    const refusal =
      "These chats were saved in format 1, and this sandbox's Codevisor reads format 2"
    const harness = await archived({ refusesRestore: refusal })

    const { machine } = await restored(harness)

    expect(machine).toMatchObject({ state: "archived", workspaceId: "id-2", hasSavedChats: true })
    expect(harness.logs).toContain(
      `Restoring sandbox Spike box (${machine.id}) failed, so it is archived again: ${refusal}`
    )
    expect(harness.provider.machines.size).toBe(0)
    expect(await harness.deps.savedChats.manifest("id-2")).toMatchObject({ chats: [{ session }] })
  })

  it("archives the sandbox again instead of starting without chats when they aren't on this Mac", async () => {
    const harness = await archived()
    await harness.deps.savedChats.remove("id-2")

    const { machine, putBack } = await restored(harness)

    expect(machine).toMatchObject({ state: "archived", hasSavedChats: true })
    expect(harness.logs).toContain(
      `Restoring sandbox Spike box (${machine.id}) failed, so it is archived again: The chats Spike box had before it was archived aren't on this Mac. Restore it from the Mac that archived it.`
    )
    expect(putBack).toEqual([])
  })

  it("brings back a chat that has no messages yet", async () => {
    const harness = await archived({ itemIds: [] })

    const { machine, putBack } = await restored(harness)

    expect(machine.state).toBe("ready")
    expect(putBack.map((call) => call["action"])).toEqual([
      "restore_chat",
      "restore_file",
      "finish_chat",
      "restore_pane"
    ])
  })
})
