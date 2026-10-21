import { readFile } from "node:fs/promises"

import { applyPatch, parsePatch, reversePatch } from "diff"

import { record, type JsonRecord } from "./internal.js"
import { absolutePath } from "./tool-updates.js"

export type ReadText = (path: string) => Promise<string>

const readUtf8: ReadText = (path) => readFile(path, "utf8")

interface FileDiff {
  readonly file: string
  readonly patch: string
  readonly status: string
}

const fileDiffs = (metadata: JsonRecord | undefined): ReadonlyArray<FileDiff> =>
  (Array.isArray(metadata?.files) ? metadata.files : []).flatMap((value: unknown) => {
    const file = record(value)
    return typeof file?.file === "string" &&
      typeof file.patch === "string" &&
      typeof file.status === "string"
      ? [{ file: file.file, patch: file.patch, status: file.status }]
      : []
  })

const diffBlock = async (
  file: FileDiff,
  cwd: string,
  read: ReadText
): Promise<ReadonlyArray<JsonRecord>> => {
  const path = absolutePath(file.file, cwd)
  const newText = file.status === "deleted" ? "" : await read(path)
  if (file.status === "added") return [{ type: "diff", path, oldText: null, newText }]
  const recorded = parsePatch(file.patch)[0]
  if (recorded === undefined || recorded.hunks.length === 0) return []
  const oldText = applyPatch(newText, reversePatch(recorded))
  return oldText === false ? [] : [{ type: "diff", path, oldText, newText }]
}

export const withCompletedDiffs = async (
  update: JsonRecord,
  metadata: JsonRecord | undefined,
  cwd: string,
  read: ReadText = readUtf8
): Promise<JsonRecord> => {
  const files = fileDiffs(metadata)
  if (files.length === 0) return update
  const diffs = await Promise.all(
    files.map((file) => diffBlock(file, cwd, read).catch((): ReadonlyArray<JsonRecord> => []))
  )
  const blocks = diffs.flat()
  if (blocks.length === 0) return update
  const content = Array.isArray(update.content) ? update.content : []
  return { ...update, content: [...content, ...blocks] }
}
