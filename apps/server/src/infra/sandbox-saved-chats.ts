import {
  FLEET_SANDBOX_CHATS_PATH,
  SavedChatFileChunk,
  SavedChatItem,
  SavedChatList,
  type FileMetadata,
  type Sandbox,
  type SandboxChatsAction,
  type SavedChat,
  type SavedChatResume
} from "@codevisor/api"
import { Schema } from "effect"

import type { SavedChatsManifest, SavedResumeFile } from "./sandbox-saved-chats-store.js"
import type { SandboxSetupProgress } from "./sandbox-setup-log.js"
import type { SandboxDeps } from "./sandboxes.js"

export const SAVED_CHAT_CHUNK_BYTES = 4 * 1024 * 1024
export const SAVED_CHAT_FILE_MAX_BYTES = 25 * 1024 * 1024
export const SAVED_CHAT_FILES_MAX_BYTES = 200 * 1024 * 1024
export const SAVED_CHAT_RESUME_MAX_BYTES = 100 * 1024 * 1024

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
  for (const chat of chats) await putBackChat(deps, machine, workspaceId, manifest, chat, setup)
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
    for (const file of chat.files) {
      const reason = fetched.has(file.id) ? undefined : leftOutReason(file, budget)
      if (reason !== undefined) {
        leftOut.push(leftOutLine(file, chat, reason))
        continue
      }
      if (!fetched.has(file.id)) await fetchFile(deps, machine, workspaceId, file)
      fetched.add(file.id)
      files.push(file)
    }
    const resume = await keepResume(deps, machine, workspaceId, chat, leftOut)
    chats.push({ session: chat.session, files, ...(resume === undefined ? {} : { resume }) })
  }
  for (const line of leftOut) deps.log(`Sandbox ${machine.name} (${machine.id}): ${line}`)
  const { format, panes } = list
  await deps.savedChats.finish(workspaceId, { format, chats, panes, leftOut })
  return chats.length
}

const keepResume = async (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  workspaceId: string,
  { session, resume }: SavedChat,
  leftOut: Array<string>
): Promise<SavedChatResume | undefined> => {
  if (resume === undefined) return undefined
  const size = resume.files.reduce((total, file) => total + file.sizeBytes, 0)
  if (size > SAVED_CHAT_RESUME_MAX_BYTES) {
    leftOut.push(
      `${coldLine(session.title)}: its agent session is ${megabytes(size)}, over the ${megabytes(SAVED_CHAT_RESUME_MAX_BYTES)} kept per chat`
    )
    return undefined
  }
  try {
    for (const [index, file] of resume.files.entries()) {
      await fetchResumeFile(deps, machine, workspaceId, { sessionId: session.id, index }, file)
    }
    return resume
  } catch (cause) {
    leftOut.push(`${coldLine(session.title)}: ${messageOf(cause)}`)
    return undefined
  }
}

const coldLine = (title: string): string =>
  `The agent in the chat ${title} starts a new session with a recap instead of resuming`

const fetchResumeFile = async (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  workspaceId: string,
  saved: SavedResumeFile,
  { path, sizeBytes }: SavedChatResume["files"][number]
): Promise<void> => {
  for (let offset = 0; offset < Math.max(sizeBytes, 1); offset += SAVED_CHAT_CHUNK_BYTES) {
    const length = SAVED_CHAT_CHUNK_BYTES
    const read = {
      action: "resume_file",
      sessionId: saved.sessionId,
      path,
      offset,
      length
    } as const
    const chunk = decodeChunk(await ask(deps, machine, read))
    await deps.savedChats.addResumeBytes(workspaceId, saved, Buffer.from(chunk.data, "base64"))
  }
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
  manifest: SavedChatsManifest,
  chat: SavedChatsManifest["chats"][number],
  setup: SandboxSetupProgress
): Promise<void> => {
  const { format } = manifest
  const { session, files } = chat
  await ask(deps, machine, { action: "restore_chat", format, workspaceId, session })
  for await (const item of deps.savedChats.items(workspaceId, session.id)) {
    await ask(deps, machine, { action: "restore_item", format, sessionId: session.id, item })
  }
  for (const file of files) await sendFile(deps, machine, workspaceId, file)
  await putBackResume(deps, machine, workspaceId, manifest, chat, setup)
  const { agentSessionId } = session
  await ask(deps, machine, {
    action: "finish_chat",
    format,
    sessionId: session.id,
    fileIds: files.map((file) => file.id),
    ...(agentSessionId === undefined ? {} : { agentSessionId })
  })
}

const putBackResume = async (
  deps: SandboxDeps,
  machine: PlacedSandbox,
  workspaceId: string,
  { format, leftOut }: SavedChatsManifest,
  { session, resume }: SavedChatsManifest["chats"][number],
  setup: SandboxSetupProgress
): Promise<void> => {
  const cold = coldLine(session.title)
  if (resume === undefined) {
    const isExplained = leftOut.some((line) => line.startsWith(cold))
    if (session.agentSessionId !== undefined && !isExplained) setup.log(cold)
    return
  }
  const { harnessId } = session
  try {
    for (const [index, { path, sizeBytes }] of resume.files.entries()) {
      const saved = { sessionId: session.id, index }
      for (let offset = 0; offset < Math.max(sizeBytes, 1); offset += SAVED_CHAT_CHUNK_BYTES) {
        const length = SAVED_CHAT_CHUNK_BYTES
        const bytes = await deps.savedChats.resumeBytes(workspaceId, saved, offset, length)
        const data = bytes.toString("base64")
        const write = { action: "restore_resume_file", format, harnessId, path, offset, data }
        await ask(deps, machine, { ...write, action: "restore_resume_file" })
      }
    }
  } catch (cause) {
    setup.log(`${cold}: ${messageOf(cause)}`)
  }
}

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
