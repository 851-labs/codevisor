import type { BotImportAction, BotMessage, FileMetadata } from "@codevisor/api"

import { run, type CodevisorServerServices } from "../server-context.js"

export const IMPORT_CHUNK_BYTES = 4 * 1024 * 1024

export const sendImportFiles = async (
  services: CodevisorServerServices,
  send: (action: BotImportAction) => Promise<unknown>,
  messages: ReadonlyArray<BotMessage>
): Promise<void> => {
  const fileIds = attachedFileIds(messages)
  if (fileIds.length === 0) return

  for (const fileId of missingOf(await send({ action: "missing_files", fileIds }))) {
    const file = await run(services.db.getFileMetadata(fileId))
    if (file === undefined) continue

    await sendFile(send, file, await services.attachments.read(file))
  }
}

const attachedFileIds = (messages: ReadonlyArray<BotMessage>): ReadonlyArray<string> => [
  ...new Set(messages.flatMap((message) => (message.attachments ?? []).map((file) => file.fileId)))
]

const missingOf = (answer: unknown): ReadonlyArray<string> => {
  const fileIds: unknown =
    typeof answer === "object" && answer !== null ? Reflect.get(answer, "fileIds") : undefined
  if (!Array.isArray(fileIds)) return []
  return fileIds.filter((fileId): fileId is string => typeof fileId === "string")
}

const sendFile = async (
  send: (action: BotImportAction) => Promise<unknown>,
  file: FileMetadata,
  bytes: Buffer
): Promise<void> => {
  for (let offset = 0; offset < Math.max(bytes.length, 1); offset += IMPORT_CHUNK_BYTES) {
    const data = bytes.subarray(offset, offset + IMPORT_CHUNK_BYTES).toString("base64")
    await send({ action: "file", file, offset, data })
  }
}
