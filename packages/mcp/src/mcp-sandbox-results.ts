import { randomUUID } from "node:crypto"

import type { AttachmentRef } from "@codevisor/api"
import { type CallToolResult, ContentBlockSchema } from "@modelcontextprotocol/sdk/types.js"

import { isRecord } from "./mcp-guards.js"

export type McpContent = CallToolResult["content"][number]

export interface SandboxArtifactInput {
  readonly data: Buffer
  readonly mimeType: string
  readonly toolPath: string
}

export interface SandboxArtifactPersistence {
  readonly persist: (
    artifact: SandboxArtifactInput
  ) => Promise<(AttachmentRef & { readonly path: string }) | undefined>
}

export interface SandboxArtifactCollector {
  readonly content: Array<McpContent>
  readonly maxItems: number
  readonly maxBytes: number
  readonly persistence?: SandboxArtifactPersistence
}

interface SandboxArtifactRef {
  readonly type: "artifact_ref"
  readonly artifactId: string
  readonly fileId?: string
  readonly path?: string
  readonly name?: string
  readonly mediaType: string
  readonly sizeBytes: number
  readonly emitted: boolean
}

type SandboxBlock = McpContent | SandboxArtifactRef

const base64Bytes = (value: string): number => Math.floor((value.length * 3) / 4)

const binaryPayload = (
  block: McpContent
): { readonly encoded: string; readonly mediaType: string } | undefined => {
  if (block.type === "image" || block.type === "audio") {
    return { encoded: block.data, mediaType: block.mimeType }
  }
  if (block.type === "resource" && "blob" in block.resource) {
    return {
      encoded: block.resource.blob,
      mediaType: block.resource.mimeType ?? "application/octet-stream"
    }
  }
  return undefined
}

const persistArtifact = async (
  collector: SandboxArtifactCollector,
  encoded: string,
  mediaType: string,
  toolPath: string
): Promise<(AttachmentRef & { readonly path: string }) | undefined> => {
  if (collector.persistence === undefined) return undefined
  try {
    return await collector.persistence.persist({
      data: Buffer.from(encoded, "base64"),
      mimeType: mediaType,
      toolPath
    })
  } catch {
    return undefined
  }
}

const sandboxContent = async (
  content: ReadonlyArray<McpContent>,
  collector: SandboxArtifactCollector,
  toolPath: string
): Promise<Array<SandboxBlock>> => {
  const blocks: Array<SandboxBlock> = []
  for (const block of content) {
    const payload = binaryPayload(block)
    if (payload === undefined) {
      blocks.push(block)
      continue
    }
    const { encoded, mediaType } = payload
    const sizeBytes = base64Bytes(encoded)
    const emitted = collector.content.length < collector.maxItems && sizeBytes <= collector.maxBytes
    if (emitted) collector.content.push(block)
    const stored = await persistArtifact(collector, encoded, mediaType, toolPath)
    blocks.push(
      stored === undefined
        ? { type: "artifact_ref", artifactId: randomUUID(), mediaType, sizeBytes, emitted }
        : {
            type: "artifact_ref",
            artifactId: stored.fileId,
            fileId: stored.fileId,
            path: stored.path,
            name: stored.name,
            mediaType,
            sizeBytes: stored.sizeBytes,
            emitted
          }
    )
  }
  return blocks
}

const callToolErrorMessage = (result: CallToolResult): string => {
  const messages = result.content.flatMap((block) =>
    block.type === "text" && block.text.trim().length > 0 ? [block.text.trim()] : []
  )
  return messages.join("\n") || "Tool call failed"
}

const sandboxTextBlocks = (content: ReadonlyArray<SandboxBlock>): Array<string> =>
  content.flatMap((block) => (block.type === "text" ? [block.text] : []))

const sandboxArtifactReferences = (
  content: ReadonlyArray<SandboxBlock>
): Array<SandboxArtifactRef> =>
  content.flatMap((block) => (block.type === "artifact_ref" ? [block] : []))

const sandboxRawValue = (structuredContent: unknown, textBlocks: Array<string>): unknown =>
  structuredContent ??
  (() => {
    if (textBlocks.length === 0) return undefined
    const text = textBlocks.length === 1 ? textBlocks[0]! : textBlocks
    if (typeof text !== "string") return text
    try {
      return JSON.parse(text) as unknown
    } catch {
      return text
    }
  })()

const sandboxValueWithArtifacts = (
  rawValue: unknown,
  artifacts: ReadonlyArray<SandboxArtifactRef>
): unknown => {
  if (artifacts.length === 0) return rawValue
  if (typeof rawValue === "object" && rawValue !== null && !Array.isArray(rawValue)) {
    return { ...rawValue, artifacts }
  }
  return { value: rawValue, artifacts }
}

export const sandboxSuccessfulToolResult = async (
  result: CallToolResult,
  collector: SandboxArtifactCollector,
  toolPath = "tool"
): Promise<unknown> => {
  if (result.isError === true) throw new Error(callToolErrorMessage(result))
  const content = await sandboxContent(result.content, collector, toolPath)
  const textBlocks = sandboxTextBlocks(content)
  const artifacts = sandboxArtifactReferences(content)
  const rawValue: unknown = sandboxRawValue(result.structuredContent, textBlocks)
  return sandboxValueWithArtifacts(rawValue, artifacts)
}

export const sandboxOutputContent = (
  output: ReadonlyArray<unknown> | undefined
): Array<McpContent> =>
  (output ?? []).flatMap((item) => {
    if (isRecord(item) && item.type === "content") {
      const parsed = ContentBlockSchema.safeParse(item.content)
      if (parsed.success) return [parsed.data]
    }
    return [{ type: "text" as const, text: JSON.stringify(item) }]
  })
