import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"

export type McpContent = CallToolResult["content"][number]

export interface SandboxArtifactCollector {
  readonly content: Array<McpContent>
  readonly maxItems: number
  readonly maxBytes: number
}

const base64Bytes = (value: string): number => Math.floor((value.length * 3) / 4)

const sandboxToolResult = (value: unknown, collector: SandboxArtifactCollector): unknown => {
  if (typeof value !== "object" || value === null || !("content" in value)) return value
  const result = value as { readonly content?: unknown; readonly [key: string]: unknown }
  if (!Array.isArray(result.content)) return value
  return {
    ...result,
    content: result.content.map((block) => {
      if (typeof block !== "object" || block === null) return block
      const candidate = block as Record<string, unknown>
      const encoded =
        candidate.type === "image" || candidate.type === "audio"
          ? candidate.data
          : candidate.type === "resource" &&
              typeof candidate.resource === "object" &&
              candidate.resource !== null
            ? (candidate.resource as Record<string, unknown>).blob
            : undefined
      if (typeof encoded !== "string") return block
      const artifactId = randomUUID()
      const sizeBytes = base64Bytes(encoded)
      const emitted =
        collector.content.length < collector.maxItems && sizeBytes <= collector.maxBytes
      if (emitted) {
        collector.content.push(block as McpContent)
      }
      return {
        type: "artifact_ref",
        artifactId,
        mediaType:
          typeof candidate.mimeType === "string"
            ? candidate.mimeType
            : typeof candidate.resource === "object" &&
                candidate.resource !== null &&
                typeof (candidate.resource as Record<string, unknown>).mimeType === "string"
              ? (candidate.resource as Record<string, unknown>).mimeType
              : "application/octet-stream",
        sizeBytes,
        emitted
      }
    })
  }
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
export const sandboxSuccessfulToolResult = (
  result: CallToolResult,
  collector: SandboxArtifactCollector
): unknown => {
  if (result.isError === true) throw new Error(callToolErrorMessage(result))
  const transformed = sandboxToolResult(result, collector) as {
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
  if (typeof rawValue === "object" && rawValue !== null && !Array.isArray(rawValue)) {
    return { ...rawValue, artifacts }
  }
  return { value: rawValue, artifacts }
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
