import { execFile } from "node:child_process"

/// Best-effort kill for agent-run codex commands.
///
/// The app-server protocol exposes no way to terminate a command the AGENT
/// started (`command/exec/terminate` only resolves client-initiated sessions,
/// and the item's `processId` is an internal handle, not an OS pid). But we
/// spawned the codex process ourselves, so its commands are our grandchildren:
/// walk the live process table, find descendants of the codex pid whose argv
/// contains the item's command string, and SIGTERM those subtrees. Codex
/// observes a normal command exit. Heuristic by design — no match, no kill.

export interface ProcessTableEntry {
  readonly pid: number
  readonly ppid: number
  readonly command: string
}

/// Parses `ps -axo pid=,ppid=,command=` output (two right-aligned numeric
/// columns, then the full argv).
export const parseProcessTable = (psOutput: string): Array<ProcessTableEntry> =>
  psOutput.split("\n").flatMap((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s+(.+)$/.exec(line)
    if (match === null) return []
    return [{ command: match[3]!, pid: Number(match[1]), ppid: Number(match[2]) }]
  })

/// Pids to SIGTERM for one command: every descendant of `rootPid` whose argv
/// contains the command string (falling back to its first line for very long
/// scripts that ps may truncate), plus each match's own descendants so a
/// matched shell takes its children with it.
export const commandSubtreePids = (
  entries: ReadonlyArray<ProcessTableEntry>,
  rootPid: number,
  command: string
): Array<number> => {
  const children = new Map<number, Array<ProcessTableEntry>>()
  for (const entry of entries) {
    const siblings = children.get(entry.ppid) ?? []
    siblings.push(entry)
    children.set(entry.ppid, siblings)
  }
  const descendants: Array<ProcessTableEntry> = []
  const walk = (pid: number): void => {
    for (const child of children.get(pid) ?? []) {
      descendants.push(child)
      walk(child.pid)
    }
  }
  walk(rootPid)

  const matchesBy = (needle: string): Array<ProcessTableEntry> =>
    needle.length === 0 ? [] : descendants.filter((entry) => entry.command.includes(needle))
  let matches = matchesBy(command.trim())
  if (matches.length === 0) {
    const firstLine = command.split("\n", 1)[0]?.trim() ?? ""
    if (firstLine !== command.trim()) {
      matches = matchesBy(firstLine)
    }
  }

  const pids = new Set<number>()
  const collect = (pid: number): void => {
    if (pids.has(pid)) return
    pids.add(pid)
    for (const child of children.get(pid) ?? []) {
      collect(child.pid)
    }
  }
  for (const match of matches) {
    collect(match.pid)
  }
  return [...pids]
}

export type CodexCommandKiller = (rootPid: number, command: string) => Promise<void>

/* v8 ignore start -- exercises the live process table; the pure matching logic is unit-tested above. */
const listProcesses = (): Promise<string> =>
  new Promise((resolvePromise) => {
    execFile(
      "ps",
      ["-axo", "pid=,ppid=,command="],
      { maxBuffer: 16 * 1024 * 1024 },
      (error, stdout) => {
        resolvePromise(error === null ? stdout : "")
      }
    )
  })

export const killCodexCommandProcesses: CodexCommandKiller = async (rootPid, command) => {
  const table = parseProcessTable(await listProcesses())
  for (const pid of commandSubtreePids(table, rootPid, command)) {
    try {
      process.kill(pid, "SIGTERM")
    } catch {
      // Already gone (or not ours to signal) — best effort.
    }
  }
}
/* v8 ignore stop */
