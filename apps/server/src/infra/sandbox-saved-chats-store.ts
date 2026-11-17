import { createReadStream } from "node:fs"
import { appendFile, mkdir, open, readFile, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { createInterface } from "node:readline"

import { FileMetadata, SavedChatItem, SavedChatPane, SavedChatSession } from "@codevisor/api"
import { Schema } from "effect"

export const SavedChatsManifest = Schema.Struct({
  format: Schema.Number,
  chats: Schema.Array(
    Schema.Struct({ session: SavedChatSession, files: Schema.Array(FileMetadata) })
  ),
  panes: Schema.Array(SavedChatPane),
  leftOut: Schema.Array(Schema.String)
})
export type SavedChatsManifest = typeof SavedChatsManifest.Type

export interface SavedChatsStore {
  readonly begin: (workspaceId: string) => Promise<void>
  readonly addItem: (workspaceId: string, sessionId: string, item: SavedChatItem) => Promise<void>
  readonly addFileBytes: (workspaceId: string, fileId: string, bytes: Buffer) => Promise<void>
  readonly finish: (workspaceId: string, manifest: SavedChatsManifest) => Promise<void>
  readonly manifest: (workspaceId: string) => Promise<SavedChatsManifest | undefined>
  readonly items: (workspaceId: string, sessionId: string) => AsyncIterable<SavedChatItem>
  readonly fileBytes: (
    workspaceId: string,
    fileId: string,
    offset: number,
    length: number
  ) => Promise<Buffer>
  readonly remove: (workspaceId: string) => Promise<void>
}

const decodeManifest = Schema.decodeUnknownSync(SavedChatsManifest)
const decodeItem = Schema.decodeUnknownSync(SavedChatItem)

export const makeSavedChatsStore = (dataDir: string): SavedChatsStore => {
  const folderOf = (workspaceId: string): string =>
    join(dataDir, "sandbox-saved-chats", workspaceId.toLowerCase())
  const itemsOf = (workspaceId: string, sessionId: string): string =>
    join(folderOf(workspaceId), `${sessionId.toLowerCase()}.items.ndjson`)
  const fileOf = (workspaceId: string, fileId: string): string =>
    join(folderOf(workspaceId), "files", fileId.toLowerCase())
  const manifestOf = (workspaceId: string): string => join(folderOf(workspaceId), "manifest.json")
  const remove = (workspaceId: string): Promise<void> =>
    rm(folderOf(workspaceId), { force: true, recursive: true })

  return {
    begin: async (workspaceId) => {
      await remove(workspaceId)
      await mkdir(join(folderOf(workspaceId), "files"), { recursive: true, mode: 0o700 })
    },
    addItem: (workspaceId, sessionId, item) =>
      appendFile(itemsOf(workspaceId, sessionId), `${JSON.stringify(item)}\n`, { mode: 0o600 }),
    addFileBytes: (workspaceId, fileId, bytes) =>
      appendFile(fileOf(workspaceId, fileId), bytes, { mode: 0o600 }),
    finish: (workspaceId, manifest) =>
      writeFile(manifestOf(workspaceId), JSON.stringify(manifest), { mode: 0o600 }),
    manifest: async (workspaceId) => {
      const raw = await readFile(manifestOf(workspaceId), "utf8").catch(() => undefined)
      return raw === undefined ? undefined : decodeManifest(JSON.parse(raw))
    },
    items: (workspaceId, sessionId) => savedItems(itemsOf(workspaceId, sessionId)),
    fileBytes: (workspaceId, fileId, offset, length) =>
      bytesAt(fileOf(workspaceId, fileId), offset, length),
    remove
  }
}

async function* savedItems(path: string): AsyncIterable<SavedChatItem> {
  const stream = createReadStream(path, "utf8")
  const failure = new Promise<never>((_resolve, reject) => stream.once("error", reject))
  failure.catch(() => undefined)
  const lines = createInterface({ input: stream, crlfDelay: Infinity })[Symbol.asyncIterator]()
  try {
    for (;;) {
      const next = await Promise.race([lines.next(), failure])
      if (next.done === true) return
      if (next.value !== "") yield decodeItem(JSON.parse(next.value))
    }
  } finally {
    stream.destroy()
  }
}

const bytesAt = async (path: string, offset: number, length: number): Promise<Buffer> => {
  const handle = await open(path, "r")
  try {
    const { bytesRead, buffer } = await handle.read(Buffer.alloc(length), 0, length, offset)
    return buffer.subarray(0, bytesRead)
  } finally {
    await handle.close()
  }
}
