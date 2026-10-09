import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

/// Reads the conversation the CLI writes for each subagent as it runs, at
/// `<config>/projects/<project>/<session>/subagents/agent-<id>.jsonl` (the
/// layout the SDK's `listSubagents` documents). The SDK's own readers resolve
/// the config directory from this process's environment, not the account's,
/// so the adapter reads the account's directory itself.
export interface SubagentTranscripts {
  /// The transcript of subagent `agentId` in session `sessionId`, once it exists.
  readonly locate: (sessionId: string, agentId: string) => string | undefined
  /// The whole lines written at or after byte `offset`, and the offset after them.
  readonly readLines: (
    path: string,
    offset: number
  ) => { readonly text: string; readonly offset: number }
}

const NEWLINE = 0x0a

/// The Claude config directory a CLI started with `env` uses.
export const claudeConfigDir = (env: Readonly<Record<string, string>>): string =>
  env.CLAUDE_CONFIG_DIR ?? join(env.HOME ?? homedir(), ".claude")

export const nodeSubagentTranscripts = (configDir: string): SubagentTranscripts => ({
  // Session ids are unique, so the project directory (named by a CLI-internal
  // encoding of the cwd) is found by search rather than recomputed.
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
      // A line still being written stays for the next read; stopping at a
      // newline also never splits a multi-byte character.
      const end = buffer.subarray(0, read).lastIndexOf(NEWLINE)
      if (end === -1) return { offset, text: "" }
      return { offset: offset + end + 1, text: buffer.toString("utf8", 0, end + 1) }
    } finally {
      closeSync(fd)
    }
  }
})
