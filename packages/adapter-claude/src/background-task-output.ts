import { open } from "node:fs/promises"

import { emitBackgroundTasks } from "./background-tasks.js"
import { isRecord } from "./internal.js"
import type { ClaudeSession } from "./session.js"

const backgroundOutputPattern =
  /background with ID: (\S+)\. Output is being written to: (\S+\.output)/
const tailBytes = 64 * 1024

interface OutputTail {
  readonly text: string
  readonly startsMidFile: boolean
}

interface BackgroundOutput {
  readonly taskId: string
  readonly outputFile: string
}

export const recordBackgroundTaskOutput = (session: ClaudeSession, content: unknown): void => {
  const output = backgroundOutputIn(toolResultText(content))
  if (output === undefined) return

  session.backgroundTaskOutputFiles.set(output.taskId, output.outputFile)
  if (session.backgroundTasks.has(output.taskId)) void emitBackgroundTasks(session)
}

export const readBackgroundTaskOutput = async (
  session: ClaudeSession,
  taskId: string,
  lineLimit: number
): Promise<ReadonlyArray<string> | undefined> => {
  const outputFile = session.backgroundTaskOutputFiles.get(taskId)
  if (outputFile === undefined) return undefined

  const lines = completeLines(await readTail(outputFile))
  return lines.slice(Math.max(0, lines.length - lineLimit))
}

const backgroundOutputIn = (text: string): BackgroundOutput | undefined => {
  const match = backgroundOutputPattern.exec(text)
  if (match === null) return undefined
  return { taskId: match[1]!, outputFile: match[2]! }
}

const toolResultText = (content: unknown): string => {
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  return content
    .map((block) => (isRecord(block) && typeof block.text === "string" ? block.text : ""))
    .join("\n")
}

const readTail = async (path: string): Promise<OutputTail> => {
  const file = await open(path, "r").catch(() => undefined)
  if (file === undefined) return { text: "", startsMidFile: false }
  try {
    const { size } = await file.stat()
    const start = Math.max(0, size - tailBytes)
    const buffer = Buffer.alloc(size - start)
    await file.read(buffer, 0, buffer.length, start)
    return { text: buffer.toString("utf8"), startsMidFile: start > 0 }
  } finally {
    await file.close()
  }
}

const completeLines = (tail: OutputTail): Array<string> => {
  const lines = tail.text.split("\n")
  if (lines.at(-1) === "") lines.pop()
  if (tail.startsMidFile) lines.shift()
  return lines
}
