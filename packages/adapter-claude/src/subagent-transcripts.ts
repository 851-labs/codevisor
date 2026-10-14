import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

export interface SubagentTranscripts {
  readonly locate: (sessionId: string, agentId: string) => string | undefined
  readonly readLines: (
    path: string,
    offset: number
  ) => { readonly text: string; readonly offset: number }
}

const NEWLINE = 0x0a

export const claudeConfigDir = (env: Readonly<Record<string, string>>): string =>
  env.CLAUDE_CONFIG_DIR ?? join(env.HOME ?? homedir(), ".claude")

export const nodeSubagentTranscripts = (configDir: string): SubagentTranscripts => ({
  locate: (sessionId, agentId) => {
    const projects = join(configDir, "projects")
    let entries: Array<string>
    try {
      entries = readdirSync(projects)
    } catch {
      return undefined
    }
    for (const project of entries) {
      const path = join(projects, project, sessionId, "subagents", `agent-${agentId}.jsonl`)
      if (existsSync(path)) return path
    }
    return undefined
  },
  readLines: (path, offset) => {
    let fd: number
    try {
      fd = openSync(path, "r")
    } catch {
      return { offset, text: "" }
    }
    try {
      const size = fstatSync(fd).size
      if (size <= offset) return { offset, text: "" }
      const buffer = Buffer.alloc(size - offset)
      const read = readSync(fd, buffer, 0, buffer.length, offset)
      const end = buffer.subarray(0, read).lastIndexOf(NEWLINE)
      if (end === -1) return { offset, text: "" }
      return { offset: offset + end + 1, text: buffer.toString("utf8", 0, end + 1) }
    } finally {
      closeSync(fd)
    }
  }
})
