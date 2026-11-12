import { fileInfoReply, uploadUrlReply } from "./slack-api-schemas.js"
import { SlackToolError } from "./slack-directory.js"
import { fileArguments, uploadArguments } from "./slack-tool-arguments.js"
import type { ToolRunner } from "./slack-tool-runner.js"
import { requireConfirmation } from "./slack-write-tools.js"

export const maxInlineTextBytes = 100 * 1024

export const downloadFile: ToolRunner = async (args, { api, files }) => {
  const { file } = fileArguments.parse(args)
  const info = fileInfoReply.parse(await api.call("files.info", { file })).file
  const url = info.url_private_download ?? info.url_private
  if (url === undefined) throw new SlackToolError("Slack doesn't offer a download for that file.")

  const bytes = await api.fetchFile(url)
  const name = info.name ?? info.title ?? info.id
  return {
    id: info.id,
    name,
    ...(info.mimetype === undefined ? {} : { mimetype: info.mimetype }),
    size: bytes.byteLength,
    path: await files.save(info.id, name, bytes),
    ...inlineText(info.mimetype, bytes)
  }
}

export const uploadFile: ToolRunner = async (args, { api, directory, files }) => {
  const { channel, path, title, comment, threadTs, confirm } = uploadArguments.parse(args)
  requireConfirmation("upload_file", confirm)

  const local = await files.read(path)
  const target = uploadUrlReply.parse(
    await api.call("files.getUploadURLExternal", {
      filename: local.name,
      length: local.bytes.byteLength
    })
  )
  await api.sendFile(target.upload_url, local.bytes)
  await api.call("files.completeUploadExternal", {
    files: [{ id: target.file_id, title: title ?? local.name }],
    channel_id: await directory.resolveConversation(channel),
    thread_ts: threadTs,
    initial_comment: comment
  })
  return { shared: true, file: target.file_id, name: local.name }
}

const inlineText = (mimetype: string | undefined, bytes: Uint8Array): { text?: string } => {
  if (!isText(mimetype) || bytes.byteLength > maxInlineTextBytes) return {}

  return { text: new TextDecoder().decode(bytes) }
}

const isText = (mimetype: string | undefined): boolean =>
  mimetype !== undefined && (mimetype.startsWith("text/") || textTypes.has(mimetype))

const textTypes = new Set([
  "application/json",
  "application/xml",
  "application/x-yaml",
  "application/csv"
])
