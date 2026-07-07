import { promises as fsPromises } from "node:fs"
import { homedir as osHomedir } from "node:os"
import { join } from "node:path"

/// Native harness session discovery.
///
/// Onboarding suggests workspaces from the coding-agent sessions the user ran
/// BEFORE ever installing HerdMan, and "import existing chats" lists them —
/// so these must come from the harnesses' own on-disk stores (Claude Code's
/// `~/.claude/projects`, Codex's `~/.codex/sessions`), not HerdMan's
/// database, which is empty on a fresh install by definition.

/// One session from a harness's native store.
export interface AgentSessionSummary {
  readonly sessionId: string
  readonly cwd: string
  readonly title?: string
  /// ISO timestamp of the session file's last modification.
  readonly updatedAt?: string
}

/// Filesystem seam so scanners are fully testable without real home dirs.
export interface AgentSessionFileSystem {
  /// Directory entry names (files and directories); [] when unreadable.
  readonly listDirectory: (path: string) => Promise<ReadonlyArray<string>>
  /// File stat, or undefined when unreadable / not a file.
  readonly statFile: (
    path: string
  ) => Promise<{ mtimeMs: number; isDirectory: boolean } | undefined>
  /// Up to `maxBytes` from the start of the file; undefined when unreadable.
  readonly readHead: (path: string, maxBytes: number) => Promise<string | undefined>
  /// Whether a directory exists (session cwds that were deleted are skipped).
  readonly directoryExists: (path: string) => Promise<boolean>
}

export const defaultAgentSessionFileSystem: AgentSessionFileSystem = {
  listDirectory: async (path) => {
    try {
      return await fsPromises.readdir(path)
    } catch {
      return []
    }
  },
  statFile: async (path) => {
    try {
      const stat = await fsPromises.stat(path)
      return { mtimeMs: stat.mtimeMs, isDirectory: stat.isDirectory() }
    } catch {
      return undefined
    }
  },
  readHead: async (path, maxBytes) => {
    let handle
    try {
      handle = await fsPromises.open(path, "r")
      const buffer = Buffer.alloc(maxBytes)
      const { bytesRead } = await handle.read(buffer, 0, maxBytes, 0)
      return buffer.subarray(0, bytesRead).toString("utf8")
    } catch {
      return undefined
    } finally {
      await handle?.close()
    }
  },
  directoryExists: async (path) => {
    try {
      return (await fsPromises.stat(path)).isDirectory()
    } catch {
      return false
    }
  }
}

export interface AgentSessionScanOptions {
  readonly homedir?: string
  /// Newest sessions to return; bounds file reads on machines with hundreds
  /// of session files. Default 40.
  readonly limit?: number
  /// Bytes read from the head of each session file. Default 256 KiB —
  /// enough to find the cwd and the first user message.
  readonly maxReadBytes?: number
  readonly fs?: AgentSessionFileSystem
}

const resolved = (options: AgentSessionScanOptions) => ({
  homedir: options.homedir ?? osHomedir(),
  limit: options.limit ?? 40,
  maxReadBytes: options.maxReadBytes ?? 256 * 1024,
  fs: options.fs ?? defaultAgentSessionFileSystem
})

const truncatedTitle = (text: string): string | undefined => {
  // split(..., 1) always yields at least one element.
  const firstLine = (text.trim().split("\n", 1)[0] as string).trim()
  if (firstLine.length === 0) {
    return undefined
  }
  return firstLine.length > 80 ? `${firstLine.slice(0, 79)}…` : firstLine
}

const parseJsonLine = (line: string): Record<string, unknown> | undefined => {
  try {
    const parsed: unknown = JSON.parse(line)
    return typeof parsed === "object" && parsed !== null
      ? (parsed as Record<string, unknown>)
      : undefined
  } catch {
    return undefined
  }
}

interface SessionFileCandidate {
  readonly path: string
  readonly mtimeMs: number
}

/// Newest-first candidates capped at `limit` — file reads are the expensive
/// part, so ordering happens on stat data alone.
const newestFirst = (
  candidates: ReadonlyArray<SessionFileCandidate>,
  limit: number
): ReadonlyArray<SessionFileCandidate> =>
  [...candidates].sort((a, b) => b.mtimeMs - a.mtimeMs).slice(0, limit)

/// Claude Code: `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
/// The cwd comes from the entries themselves (the encoded directory name is
/// lossy); the title from the first real user message.
export const listClaudeAgentSessions = async (
  options: AgentSessionScanOptions = {}
): Promise<ReadonlyArray<AgentSessionSummary>> => {
  const { homedir, limit, maxReadBytes, fs } = resolved(options)
  const root = join(homedir, ".claude", "projects")
  const candidates: SessionFileCandidate[] = []
  for (const project of await fs.listDirectory(root)) {
    const projectDir = join(root, project)
    for (const entry of await fs.listDirectory(projectDir)) {
      if (!entry.endsWith(".jsonl")) continue
      const path = join(projectDir, entry)
      const stat = await fs.statFile(path)
      if (stat !== undefined && !stat.isDirectory) {
        candidates.push({ path, mtimeMs: stat.mtimeMs })
      }
    }
  }

  const sessions: AgentSessionSummary[] = []
  for (const candidate of newestFirst(candidates, limit)) {
    const head = await fs.readHead(candidate.path, maxReadBytes)
    if (head === undefined) continue
    let cwd: string | undefined
    let title: string | undefined
    for (const line of head.split("\n")) {
      const entry = parseJsonLine(line)
      if (entry === undefined) continue
      if (cwd === undefined && typeof entry.cwd === "string" && entry.cwd.length > 0) {
        cwd = entry.cwd
      }
      if (title === undefined && entry.type === "user" && entry.isMeta !== true) {
        title = truncatedTitle(claudeUserText(entry))
      }
      if (cwd !== undefined && title !== undefined) break
    }
    if (cwd === undefined || !(await fs.directoryExists(cwd))) continue
    sessions.push({
      // The filename is the session id.
      sessionId: fileStem(candidate.path),
      cwd,
      ...(title === undefined ? {} : { title }),
      updatedAt: new Date(candidate.mtimeMs).toISOString()
    })
  }
  return sessions
}

const claudeUserText = (entry: Record<string, unknown>): string => {
  const message = entry.message as { content?: unknown } | undefined
  const content = message?.content
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  return content
    .filter(
      (block): block is { type: string; text: string } =>
        typeof block === "object" &&
        block !== null &&
        (block as { type?: unknown }).type === "text" &&
        typeof (block as { text?: unknown }).text === "string"
    )
    .map((block) => block.text)
    .join("\n")
}

/// Candidates are pre-filtered to `*.jsonl`, so stripping the suffix is safe.
const fileStem = (path: string): string => {
  const parts = path.split("/")
  // split always yields at least one element.
  const name = parts[parts.length - 1] as string
  return name.slice(0, -".jsonl".length)
}

/// Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, first line is a
/// `session_meta` entry carrying the id and cwd; the title comes from the
/// first `user_message` event.
export const listCodexAgentSessions = async (
  options: AgentSessionScanOptions = {}
): Promise<ReadonlyArray<AgentSessionSummary>> => {
  const { homedir, limit, maxReadBytes, fs } = resolved(options)
  const root = join(homedir, ".codex", "sessions")
  const candidates: SessionFileCandidate[] = []
  const walk = async (directory: string, depth: number): Promise<void> => {
    for (const entry of await fs.listDirectory(directory)) {
      const path = join(directory, entry)
      const stat = await fs.statFile(path)
      if (stat === undefined) continue
      if (stat.isDirectory) {
        // sessions/YYYY/MM/DD — bounded in case of unexpected nesting.
        if (depth < 4) await walk(path, depth + 1)
      } else if (entry.startsWith("rollout-") && entry.endsWith(".jsonl")) {
        candidates.push({ path, mtimeMs: stat.mtimeMs })
      }
    }
  }
  await walk(root, 0)

  const sessions: AgentSessionSummary[] = []
  for (const candidate of newestFirst(candidates, limit)) {
    const head = await fs.readHead(candidate.path, maxReadBytes)
    if (head === undefined) continue
    let meta: { id?: unknown; cwd?: unknown } | undefined
    let title: string | undefined
    for (const line of head.split("\n")) {
      const entry = parseJsonLine(line)
      if (entry === undefined) continue
      if (meta === undefined && entry.type === "session_meta") {
        meta = entry.payload as { id?: unknown; cwd?: unknown } | undefined
      }
      if (title === undefined) {
        const payload = entry.payload as { type?: unknown; message?: unknown } | undefined
        if (payload?.type === "user_message" && typeof payload.message === "string") {
          title = truncatedTitle(payload.message)
        }
      }
      if (meta !== undefined && title !== undefined) break
    }
    if (typeof meta?.id !== "string" || typeof meta.cwd !== "string") continue
    if (!(await fs.directoryExists(meta.cwd))) continue
    sessions.push({
      sessionId: meta.id,
      cwd: meta.cwd,
      ...(title === undefined ? {} : { title }),
      updatedAt: new Date(candidate.mtimeMs).toISOString()
    })
  }
  return sessions
}
