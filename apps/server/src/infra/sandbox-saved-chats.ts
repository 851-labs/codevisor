import {
  FLEET_SANDBOX_CHATS_PATH,
  SavedChatFileChunk,
  SavedChatItem,
  SavedChatList,
  type FileMetadata,
  type Sandbox,
  type SandboxChatsAction,
  type SavedChat
} from "@codevisor/api"
import { Schema } from "effect"

import type { SavedChatsManifest } from "./sandbox-saved-chats-store.js"
import type { SandboxSetupProgress } from "./sandbox-setup-log.js"
import type { SandboxDeps } from "./sandboxes.js"

export const SAVED_CHAT_CHUNK_BYTES = 4 * 1024 * 1024
export const SAVED_CHAT_FILE_MAX_BYTES = 25 * 1024 * 1024
export const SAVED_CHAT_FILES_MAX_BYTES = 200 * 1024 * 1024

export type KeptChats = Pick<Sandbox, "hasSavedChats" | "chatsLost">

type PlacedSandbox = Sandbox & { readonly machineId: string }

const decodeList = Schema.decodeUnknownSync(SavedChatList)
const decodeItem = Schema.decodeUnknownSync(SavedChatItem)
const decodeChunk = Schema.decodeUnknownSync(SavedChatFileChunk)

export const keepChats = async (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  workspaceId: string
): Promise<KeptChats> => {
  try {
    const saved = await saveChats(deps, machine, workspaceId)
    return saved === 0 ? {} : { hasSavedChats: true }
  } catch (cause) {
    await deps.savedChats.remove(workspaceId).catch(() => undefined)
    const chatsLost = `Its chats couldn't be saved when it was archived: ${messageOf(cause)}`
    deps.log(`Sandbox ${machine.name} (${machine.id}): ${chatsLost}`)
    return { chatsLost }
  }
}

export const keptChatsOf = (machine: Sandbox): KeptChats => ({
  ...(machine.hasSavedChats === true ? { hasSavedChats: true } : {}),
  ...(machine.chatsLost === undefined ? {} : { chatsLost: machine.chatsLost })
})

export const bringBackChats = async (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  setup: SandboxSetupProgress
): Promise<void> => {
  const { workspaceId } = machine
  if (machine.restoresWorkspace !== true || workspaceId === undefined) return
  if (machine.chatsLost !== undefined)
    setup.log(`Its earlier chats weren't kept. ${machine.chatsLost}`)
  if (machine.hasSavedChats !== true) return

  const manifest = await deps.savedChats.manifest(workspaceId)
  if (manifest === undefined) {
    throw new Error(
      `The chats ${machine.name} had before it was archived aren't on this Mac. Restore it from the Mac that archived it.`
    )
  }
  const { format, chats, panes } = manifest
  for (const chat of chats) await putBackChat(deps, machine, workspaceId, manifest, chat)
  for (const pane of panes)
    await ask(deps, machine, { action: "restore_pane", format, workspaceId, pane })
  setup.log(
    `Brought back ${chats.length === 1 ? "1 chat with its" : `${String(chats.length)} chats with their`} history`
  )
  for (const line of manifest.leftOut) setup.log(line)
}

export const forgetBroughtBackChats = async (
  deps: SandboxDeps,
  machine: Sandbox
): Promise<void> => {
  if (machine.restoresWorkspace !== true || machine.workspaceId === undefined) return

  await deps.savedChats.remove(machine.workspaceId)
}

const saveChats = async (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  workspaceId: string
): Promise<number> => {
  const list = decodeList(await ask(deps, machine, { action: "list", workspaceId }))
  if (list.chats.length === 0) return 0

  await deps.savedChats.begin(workspaceId)
  const budget = { left: SAVED_CHAT_FILES_MAX_BYTES }
  const leftOut: Array<string> = []
  const chats: Array<SavedChatsManifest["chats"][number]> = []
  const fetched = new Set<string>()
  for (const chat of list.chats) {
    for (const itemId of chat.itemIds) {
      const item = decodeItem(await ask(deps, machine, { action: "item", itemId }))
      await deps.savedChats.addItem(workspaceId, chat.session.id, item)
    }
    const files: Array<FileMetadata> = []
    const notKept: Array<string> = []
    for (const file of chat.files) {
      const reason = fetched.has(file.id) ? undefined : leftOutReason(file, budget)
      if (reason !== undefined) {
        leftOut.push(leftOutLine(file, chat, reason))
        notKept.push(`${file.name} (${megabytes(file.sizeBytes)})`)
        continue
      }
      if (!fetched.has(file.id)) await fetchFile(deps, machine, workspaceId, file)
      fetched.add(file.id)
      files.push(file)
    }
    chats.push({ session: chat.session, files, ...(notKept.length === 0 ? {} : { notKept }) })
  }
  for (const line of leftOut) deps.log(`Sandbox ${machine.name} (${machine.id}): ${line}`)
  const { format, panes } = list
  await deps.savedChats.finish(workspaceId, { format, chats, panes, leftOut })
  return chats.length
}

const leftOutReason = (file: FileMetadata, budget: { left: number }): string | undefined => {
  if (file.sizeBytes > SAVED_CHAT_FILE_MAX_BYTES) {
    return `it is over the ${megabytes(SAVED_CHAT_FILE_MAX_BYTES)} kept per attachment`
  }
  if (file.sizeBytes > budget.left) {
    return `this sandbox's attachments passed the ${megabytes(SAVED_CHAT_FILES_MAX_BYTES)} kept per sandbox`
  }
  budget.left -= file.sizeBytes
  return undefined
}

const leftOutLine = (file: FileMetadata, chat: SavedChat, reason: string): string =>
  `Left out the attachment ${file.name} (${megabytes(file.sizeBytes)}) from the chat ${chat.session.title}: ${reason}`

const fetchFile = async (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  workspaceId: string,
  file: FileMetadata
): Promise<void> => {
  for (let offset = 0; offset < Math.max(file.sizeBytes, 1); offset += SAVED_CHAT_CHUNK_BYTES) {
    const action = {
      action: "file",
      fileId: file.id,
      offset,
      length: SAVED_CHAT_CHUNK_BYTES
    } as const
    const chunk = decodeChunk(await ask(deps, machine, action))
    await deps.savedChats.addFileBytes(workspaceId, file.id, Buffer.from(chunk.data, "base64"))
  }
}

const putBackChat = async (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  workspaceId: string,
  { format }: SavedChatsManifest,
  chat: SavedChatsManifest["chats"][number]
): Promise<void> => {
  const { session, files } = chat
  await ask(deps, machine, { action: "restore_chat", format, workspaceId, session })
  for await (const item of deps.savedChats.items(workspaceId, session.id)) {
    await ask(deps, machine, { action: "restore_item", format, sessionId: session.id, item })
  }
  for (const file of files) await sendFile(deps, machine, workspaceId, file)
  const { agentSessionId } = session
  await ask(deps, machine, {
    action: "finish_chat",
    format,
    sessionId: session.id,
    fileIds: files.map((file) => file.id),
    note: `${restoredNote(agentSessionId)}${notKeptNote(chat.notKept ?? [])}`,
    ...(agentSessionId === undefined ? {} : { agentSessionId })
  })
}

const notKeptNote = (notKept: ReadonlyArray<string>): string =>
  notKept.length === 0 ? "" : ` Too large to keep: ${notKept.join(", ")}.`

const restoredNote = (agentSessionId: string | undefined): string =>
  agentSessionId === undefined ? RESTORED_CHAT_NOTE : RECAPPED_CHAT_NOTE

export const RECAPPED_CHAT_NOTE =
  "Restored from an archived sandbox. The agent starts a new session from here and may not remember everything above."

export const RESTORED_CHAT_NOTE =
  "Restored from an archived sandbox. The agent starts fresh from here and doesn't remember the messages above."

const sendFile = async (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  workspaceId: string,
  file: FileMetadata
): Promise<void> => {
  for (let offset = 0; offset < Math.max(file.sizeBytes, 1); offset += SAVED_CHAT_CHUNK_BYTES) {
    const bytes = await deps.savedChats.fileBytes(
      workspaceId,
      file.id,
      offset,
      SAVED_CHAT_CHUNK_BYTES
    )
    const data = bytes.toString("base64")
    await ask(deps, machine, { action: "restore_file", file, offset, data })
  }
}

const ask = (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  action: SandboxChatsAction
): Promise<unknown> => deps.remoteTools.call(machine.machineId, FLEET_SANDBOX_CHATS_PATH, action)

const megabytes = (bytes: number): string =>
  `${String(Math.max(1, Math.round(bytes / (1024 * 1024))))} MB`

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
