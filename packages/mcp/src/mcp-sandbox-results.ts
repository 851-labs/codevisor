import type { AttachmentRef } from "@codevisor/api"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"

export type McpContent = CallToolResult["content"][number]

/// Attachment URLs the transcript renderers resolve to server files. The
/// origin is deliberately unroutable: it is an identifier, not a location.
export const ATTACHMENT_URL_ORIGIN = "https://attachments.codevisor.invalid/"

export const attachmentUrl = (fileId: string): string => `${ATTACHMENT_URL_ORIGIN}${fileId}`

export interface SandboxArtifactInput {
  readonly data: Buffer
  readonly mimeType: string
  /// The tool path that produced the bytes, e.g. `browser.screenshot`; names the stored file.
  readonly toolPath: string
}

/// Persists emitted bytes as an immutable server file so the agent can hand
/// the user a real attachment instead of an unreachable in-memory blob.
export interface SandboxArtifactPersistence {
  readonly persist: (artifact: SandboxArtifactInput) => Promise<AttachmentRef | undefined>
}

export interface SandboxArtifactCollector {
  readonly content: Array<McpContent>
  readonly maxItems: number
  readonly maxBytes: number
  readonly persistence?: SandboxArtifactPersistence
}

export const SHOW_TO_USER_HINT =
  "To show an artifact to the user, embed its url in your reply as ![label](url). Do not invent other paths."

const base64Bytes = (value: string): number => Math.floor((value.length * 3) / 4)

const blockMediaType = (candidate: Record<string, unknown>): string =>
  typeof candidate.mimeType === "string"
    ? candidate.mimeType
    : typeof candidate.resource === "object" &&
        candidate.resource !== null &&
        typeof (candidate.resource as Record<string, unknown>).mimeType === "string"
      ? ((candidate.resource as Record<string, unknown>).mimeType as string)
      : "application/octet-stream"

const persistArtifact = async (
  collector: SandboxArtifactCollector,
  encoded: string,
  mediaType: string,
  toolPath: string
): Promise<AttachmentRef | undefined> => {
  if (collector.persistence === undefined) return undefined
  try {
    return await collector.persistence.persist({
      data: Buffer.from(encoded, "base64"),
      mimeType: mediaType,
      toolPath
    })
  } catch {
    // Persistence is best effort: the bytes still reach the model as content.
    return undefined
  }
}

const sandboxToolResult = async (
  value: unknown,
  collector: SandboxArtifactCollector,
  toolPath: string
): Promise<unknown> => {
  if (typeof value !== "object" || value === null || !("content" in value)) return value
  const result = value as { readonly content?: unknown; readonly [key: string]: unknown }
  if (!Array.isArray(result.content)) return value
  const content: Array<unknown> = []
  for (const block of result.content) {
    if (typeof block !== "object" || block === null) {
      content.push(block)
      continue
    }
    const candidate = block as Record<string, unknown>
    const encoded =
      candidate.type === "image" || candidate.type === "audio"
        ? candidate.data
        : candidate.type === "resource" &&
            typeof candidate.resource === "object" &&
            candidate.resource !== null
          ? (candidate.resource as Record<string, unknown>).blob
          : undefined
    if (typeof encoded !== "string") {
      content.push(block)
      continue
    }
    const mediaType = blockMediaType(candidate)
    const sizeBytes = base64Bytes(encoded)
    const emitted = collector.content.length < collector.maxItems && sizeBytes <= collector.maxBytes
    if (emitted) collector.content.push(block as McpContent)
    const stored = await persistArtifact(collector, encoded, mediaType, toolPath)
    content.push(
      stored === undefined
        ? { type: "artifact_ref", artifactId: randomUUID(), mediaType, sizeBytes, emitted }
        : {
            type: "artifact_ref",
            artifactId: stored.fileId,
            fileId: stored.fileId,
            url: attachmentUrl(stored.fileId),
            name: stored.name,
            mediaType,
            sizeBytes: stored.sizeBytes,
            emitted
          }
    )
  }
  return { ...result, content }
}

const callToolErrorMessage = (result: CallToolResult): string => {
  const messages = result.content.flatMap((block) =>
    block.type === "text" && block.text.trim().length > 0 ? [block.text.trim()] : []
  )
  return messages.join("\n") || "Tool call failed"
}

/// Native Computer Use and browser-client methods reject their promises on a
/// failed action. Mirror that behavior inside execute instead of handing the
/// model a truthy `{ isError: true }` object that it can accidentally ignore.
export const sandboxSuccessfulToolResult = async (
  result: CallToolResult,
  collector: SandboxArtifactCollector,
  toolPath = "tool"
): Promise<unknown> => {
  if (result.isError === true) throw new Error(callToolErrorMessage(result))
  const transformed = (await sandboxToolResult(result, collector, toolPath)) as {
    readonly content?: ReadonlyArray<unknown>
    readonly structuredContent?: unknown
  }
  if (transformed.structuredContent !== undefined) return transformed.structuredContent
  if (!Array.isArray(transformed.content)) return transformed

  const textBlocks = transformed.content.flatMap((block) =>
    typeof block === "object" && block !== null && (block as { type?: unknown }).type === "text"
      ? [String((block as { text?: unknown }).text ?? "")]
      : []
  )
  const artifacts = transformed.content.filter(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "artifact_ref"
  )
  const rawValue: unknown = (() => {
    if (textBlocks.length === 0) return undefined
    const text = textBlocks.length === 1 ? textBlocks[0]! : textBlocks
    if (typeof text !== "string") return text
    try {
      return JSON.parse(text) as unknown
    } catch {
      return text
    }
  })()
  if (artifacts.length === 0) return rawValue
  const persisted = artifacts.some(
    (artifact) => typeof (artifact as { url?: unknown }).url === "string"
  )
  const hint = persisted ? { showToUser: SHOW_TO_USER_HINT } : {}
  if (typeof rawValue === "object" && rawValue !== null && !Array.isArray(rawValue)) {
    return { ...rawValue, artifacts, ...hint }
  }
  return { value: rawValue, artifacts, ...hint }
}

export const sandboxOutputContent = (
  output: ReadonlyArray<unknown> | undefined
): Array<McpContent> =>
  (output ?? []).flatMap((item) => {
    if (
      typeof item === "object" &&
      item !== null &&
      (item as { type?: unknown }).type === "content" &&
      typeof (item as { content?: unknown }).content === "object" &&
      (item as { content?: unknown }).content !== null
    ) {
      return [(item as { content: McpContent }).content]
    }
    return [{ type: "text" as const, text: JSON.stringify(item) }]
  })
