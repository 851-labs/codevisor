import { readFile } from "node:fs/promises"
import type { ServerResponse } from "node:http"

import { HttpFailure, writeJson } from "../server-context.js"
import { stringField } from "../unknown-values.js"
import { expandFsPath } from "./fs-paths.js"

export const READ_DEFAULT_LINES = 2_000

export interface ReadFileResult {
  readonly path: string
  readonly content: string
  readonly startLine: number
  readonly endLine: number
  readonly totalLines: number
}

export const readTextFile = async (response: ServerResponse, url: URL): Promise<boolean> => {
  const path = expandFsPath(url.searchParams.get("path") ?? "")
  const text = await readText(path)
  writeJson(response, 200, numberedSlice(path, text, lineWindow(url)))
  return true
}

interface LineWindow {
  readonly offset: number
  readonly limit: number
}

const lineWindow = (url: URL): LineWindow => ({
  offset: positiveInteger(url.searchParams.get("offset")) ?? 1,
  limit: positiveInteger(url.searchParams.get("limit")) ?? READ_DEFAULT_LINES
})

const positiveInteger = (value: string | null): number | undefined => {
  const parsed = value === null ? Number.NaN : Number(value)
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined
}

const readText = async (path: string): Promise<string> => {
  let bytes: Buffer
  try {
    bytes = await readFile(path)
  } catch (cause) {
    return throwReadFailure(path, cause)
  }
  if (bytes.includes(0)) throw new HttpFailure(415, `${path} is a binary file`, "binary_file")
  return bytes.toString("utf8")
}

const numberedSlice = (path: string, text: string, window: LineWindow): ReadFileResult => {
  const lines = text.split("\n")
  if (lines.at(-1) === "") lines.pop()
  const start = Math.min(window.offset, lines.length + 1)
  const slice = lines.slice(start - 1, start - 1 + window.limit)
  const content = slice.map((line, index) => `${start + index}\t${line}`).join("\n")
  return {
    path,
    content,
    startLine: start,
    endLine: start + slice.length - 1,
    totalLines: lines.length
  }
}

const throwReadFailure = (path: string, cause: unknown): never => {
  const code = stringField(cause, "code") ?? ""
  if (code === "ENOENT") throw new HttpFailure(404, `No such file: ${path}`, "not_found")
  if (code === "EISDIR") throw new HttpFailure(400, `${path} is a folder`, "not_a_file")
  if (["EACCES", "EPERM"].includes(code)) {
    throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
  }
  throw cause
}
