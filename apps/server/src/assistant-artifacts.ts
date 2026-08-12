import type { AttachmentRef, FileMetadata } from "@codevisor/api"
import type { AttachmentStore, CodevisorDatabaseService } from "@codevisor/db"
import { randomUUID } from "node:crypto"
import { createReadStream } from "node:fs"
import { mkdir, readdir, realpath, stat } from "node:fs/promises"
import { basename, extname, isAbsolute, join, relative, resolve, sep } from "node:path"
import { fileURLToPath } from "node:url"
import { fromMarkdown } from "mdast-util-from-markdown"
import { Effect } from "effect"

export const ASSISTANT_ARTIFACT_ORIGIN = "https://attachments.codevisor.invalid/"
const MAX_ARTIFACT_BYTES = 256 * 1024 * 1024
const MAX_ARTIFACTS_PER_TURN = 12
const MAX_SCAN_ENTRIES = 256

const attachableExtensions = new Set([
  ".aac",
  ".aiff",
  ".avi",
  ".bmp",
  ".csv",
  ".doc",
  ".docx",
  ".gif",
  ".heic",
  ".jpeg",
  ".jpg",
  ".json",
  ".m4a",
  ".m4v",
  ".mov",
  ".mp3",
  ".mp4",
  ".pdf",
  ".png",
  ".ppt",
  ".pptx",
  ".tar",
  ".tiff",
  ".tsv",
  ".txt",
  ".wav",
  ".webm",
  ".webp",
  ".xls",
  ".xlsx",
  ".zip"
])

const mimeTypes: Readonly<Record<string, string>> = {
  ".aac": "audio/aac",
  ".aiff": "audio/aiff",
  ".avi": "video/x-msvideo",
  ".bmp": "image/bmp",
  ".csv": "text/csv",
  ".doc": "application/msword",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".gif": "image/gif",
  ".heic": "image/heic",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".json": "application/json",
  ".m4a": "audio/mp4",
  ".m4v": "video/mp4",
  ".mov": "video/quicktime",
  ".mp3": "audio/mpeg",
  ".mp4": "video/mp4",
  ".pdf": "application/pdf",
  ".png": "image/png",
  ".ppt": "application/vnd.ms-powerpoint",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ".tiff": "image/tiff",
  ".tsv": "text/tab-separated-values",
  ".txt": "text/plain",
  ".wav": "audio/wav",
  ".webm": "video/webm",
  ".webp": "image/webp",
  ".xls": "application/vnd.ms-excel",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".zip": "application/zip"
}

type MarkdownNode = {
  readonly type?: string
  readonly url?: string
  readonly position?: {
    readonly start?: { readonly offset?: number }
    readonly end?: { readonly offset?: number }
  }
  readonly children?: ReadonlyArray<MarkdownNode>
}

type LinkTarget = {
  readonly start: number
  readonly end: number
  readonly url: string
}

export interface AssistantArtifactFinalization {
  readonly markdown: string
  readonly attachments: ReadonlyArray<AttachmentRef>
  readonly changed: boolean
}

export interface AssistantArtifactServices {
  readonly attachments: AttachmentStore
  readonly db: CodevisorDatabaseService
}

export const assistantArtifactDirectory = (cwd: string, sessionId: string): string =>
  join(cwd, ".codevisor", "artifacts", sessionId)

export const assistantArtifactGuidance = (directory: string): string =>
  [
    "[Codevisor artifact delivery]",
    "When a user-facing file would help, save it in this directory:",
    directory,
    "Link it in your final response with ordinary Markdown. Files in this directory are attached automatically, even if you forget the link."
  ].join("\n")

const safeDecode = (value: string): string => {
  try {
    return decodeURIComponent(value)
  } catch {
    return value
  }
}

const markdownLinkTargets = (markdown: string): ReadonlyArray<LinkTarget> => {
  let tree: MarkdownNode
  try {
    tree = fromMarkdown(markdown) as MarkdownNode
  } catch {
    /* v8 ignore next -- mdast accepts arbitrary Markdown strings; retain a fail-open guard for parser upgrades. */
    return []
  }
  const targets: LinkTarget[] = []
  const visit = (node: MarkdownNode): void => {
    if (
      (node.type === "link" || node.type === "image" || node.type === "definition") &&
      typeof node.url === "string"
    ) {
      const nodeStart = node.position?.start?.offset
      const nodeEnd = node.position?.end?.offset
      /* v8 ignore next -- mdast link, image, and definition nodes always include source offsets. */
      if (nodeStart !== undefined && nodeEnd !== undefined) {
        const source = markdown.slice(nodeStart, nodeEnd)
        const rawIndex = source.lastIndexOf(node.url)
        const decodedIndex = rawIndex === -1 ? source.lastIndexOf(safeDecode(node.url)) : -1
        const index = rawIndex === -1 ? decodedIndex : rawIndex
        const renderedUrl = rawIndex === -1 ? safeDecode(node.url) : node.url
        if (index !== -1) {
          targets.push({
            start: nodeStart + index,
            end: nodeStart + index + renderedUrl.length,
            url: node.url
          })
        }
      }
    }
    for (const child of node.children ?? []) visit(child)
  }
  visit(tree)
  return targets.sort((left, right) => left.start - right.start)
}

const pathInside = (root: string, candidate: string): boolean => {
  const child = relative(root, candidate)
  return child === "" || (!child.startsWith(`..${sep}`) && child !== ".." && !isAbsolute(child))
}

const localPathForUrl = (url: string, cwd: string): string | undefined => {
  if (url.startsWith(ASSISTANT_ARTIFACT_ORIGIN) || url.startsWith("#")) return undefined
  if (url.startsWith("file://")) {
    try {
      return fileURLToPath(url)
    } catch {
      return undefined
    }
  }
  // A colon before any path separator denotes a URI scheme. Source-navigation
  // suffixes such as `file.ts:42` simply fail the regular-file check below.
  if (/^[a-z][a-z0-9+.-]*:/i.test(url)) return undefined
  const decoded = safeDecode(url)
  return isAbsolute(decoded) ? decoded : resolve(cwd, decoded)
}

const mimeTypeForPath = (path: string): string =>
  mimeTypes[extname(path).toLowerCase()] ?? "application/octet-stream"

const attachmentKind = (mimeType: string): "image" | "file" =>
  mimeType.startsWith("image/") ? "image" : "file"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const promoteFile = async (
  services: AssistantArtifactServices,
  path: string,
  existingBySha256: Map<string, AttachmentRef>
): Promise<AttachmentRef> => {
  const object = await services.attachments.putStream(createReadStream(path))
  const existing = existingBySha256.get(object.sha256)
  if (existing !== undefined) return existing
  const name = basename(path)
    .replaceAll("\0", "_")
    .replace(/[/\\:]/g, "_")
  const mimeType = mimeTypeForPath(path)
  const metadata: FileMetadata = {
    id: randomUUID(),
    name,
    mimeType,
    sizeBytes: object.sizeBytes,
    sha256: object.sha256,
    kind: attachmentKind(mimeType),
    createdAt: new Date().toISOString()
  }
  await run(services.db.createDiskFile(metadata))
  const attachment: AttachmentRef = {
    fileId: metadata.id,
    name: metadata.name,
    mimeType: metadata.mimeType,
    sizeBytes: metadata.sizeBytes,
    kind: metadata.kind
  }
  existingBySha256.set(object.sha256, attachment)
  return attachment
}

const eligibleFile = async (
  rawPath: string,
  realCwd: string,
  realManagedDirectory: string
): Promise<string | undefined> => {
  try {
    const resolved = await realpath(rawPath)
    if (!pathInside(realCwd, resolved)) return undefined
    const info = await stat(resolved)
    if (!info.isFile() || info.size > MAX_ARTIFACT_BYTES) return undefined
    if (
      !pathInside(realManagedDirectory, resolved) &&
      !attachableExtensions.has(extname(resolved).toLowerCase())
    ) {
      return undefined
    }
    return resolved
  } catch {
    return undefined
  }
}

const recentManagedFiles = async (
  directory: string,
  newerThan: number
): Promise<ReadonlyArray<string>> => {
  const files: string[] = []
  let visited = 0
  const walk = async (path: string): Promise<void> => {
    let entries
    try {
      entries = await readdir(path, { withFileTypes: true })
    } catch {
      /* v8 ignore next -- requires the managed directory to disappear during this bounded scan. */
      return
    }
    for (const entry of entries) {
      if (visited >= MAX_SCAN_ENTRIES || files.length >= MAX_ARTIFACTS_PER_TURN) return
      visited += 1
      const child = join(path, entry.name)
      if (entry.isDirectory()) {
        await walk(child)
      } else if (entry.isFile()) {
        try {
          if ((await stat(child)).mtimeMs >= newerThan) files.push(child)
        } catch {
          // The agent may still be atomically replacing an artifact; a linked
          // file gets another chance in the explicit Markdown pass.
        }
      }
    }
  }
  await walk(directory)
  return files
}

export const finalizeAssistantArtifacts = async (
  services: AssistantArtifactServices,
  options: {
    readonly cwd: string
    readonly sessionId: string
    readonly markdown: string
    readonly startedAt?: string | undefined
    readonly existingAttachments?: ReadonlyArray<AttachmentRef> | undefined
  }
): Promise<AssistantArtifactFinalization> => {
  const directory = assistantArtifactDirectory(options.cwd, options.sessionId)
  await mkdir(directory, { recursive: true })
  const [realCwd, realDirectory] = await Promise.all([realpath(options.cwd), realpath(directory)])
  const attachments = [...(options.existingAttachments ?? [])]
  const attachmentIds = new Set(attachments.map((attachment) => attachment.fileId))
  const existingBySha256 = new Map<string, AttachmentRef>()
  for (const attachment of attachments) {
    const metadata = await run(services.db.getFileMetadata(attachment.fileId))
    if (metadata !== undefined) existingBySha256.set(metadata.sha256, attachment)
  }
  const promotedByPath = new Map<string, AttachmentRef>()
  const replacements: Array<LinkTarget & { readonly replacement: string }> = []

  for (const target of markdownLinkTargets(options.markdown)) {
    if (attachments.length >= MAX_ARTIFACTS_PER_TURN) break
    const rawPath = localPathForUrl(target.url, options.cwd)
    if (rawPath === undefined) continue
    const path = await eligibleFile(rawPath, realCwd, realDirectory)
    if (path === undefined) continue
    let attachment = promotedByPath.get(path)
    if (attachment === undefined) {
      try {
        attachment = await promoteFile(services, path, existingBySha256)
      } catch {
        // A file can be atomically replaced or removed while the provider is
        // finishing its response. Leave only that link untouched.
        continue
      }
      promotedByPath.set(path, attachment)
      if (!attachmentIds.has(attachment.fileId)) {
        attachmentIds.add(attachment.fileId)
        attachments.push(attachment)
      }
    }
    replacements.push({
      ...target,
      replacement: `${ASSISTANT_ARTIFACT_ORIGIN}${attachment.fileId}`
    })
  }

  const cutoff = Math.max(0, Date.parse(options.startedAt ?? "") - 2_000 || Date.now() - 60_000)
  for (const rawPath of await recentManagedFiles(directory, cutoff)) {
    if (attachments.length >= MAX_ARTIFACTS_PER_TURN) break
    const path = await eligibleFile(rawPath, realCwd, realDirectory)
    if (path === undefined || promotedByPath.has(path)) continue
    let attachment: AttachmentRef
    try {
      attachment = await promoteFile(services, path, existingBySha256)
    } catch {
      continue
    }
    promotedByPath.set(path, attachment)
    if (!attachmentIds.has(attachment.fileId)) {
      attachmentIds.add(attachment.fileId)
      attachments.push(attachment)
    }
  }

  let markdown = options.markdown
  for (const replacement of [...replacements].reverse()) {
    markdown = `${markdown.slice(0, replacement.start)}${replacement.replacement}${markdown.slice(replacement.end)}`
  }
  return {
    markdown,
    attachments,
    changed:
      markdown !== options.markdown ||
      attachments.length !== (options.existingAttachments?.length ?? 0)
  }
}
