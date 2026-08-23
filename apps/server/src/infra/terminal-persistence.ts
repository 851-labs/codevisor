/// Terminal replay buffers across host restarts.
///
/// The terminal manager's frame buffers are in-memory, so a server restart
/// (self-update handoff, `codevisor stop`, service restart) used to lose every
/// terminal's scrollback and break `lastOutputSeq` replay for reconnecting
/// clients. This module snapshots the buffers to `<dataDir>/terminal-buffers.json`
/// on every graceful exit path and restores them on the next boot.
///
/// Restored terminals are closed and process-less (the processes died with the
/// previous server): clients replay scrollback and see an exit, then create
/// fresh terminals as usual. Crash loss is acceptable — this covers graceful
/// exits, which is what host updates go through. All writes are synchronous so
/// they are safe inside `process.on("exit")`.
import type { TerminalManagerService, TerminalSnapshot } from "@codevisor/terminal"
import { readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const SNAPSHOT_FILE = "terminal-buffers.json"

export interface TerminalPersistenceOptions {
  readonly dataDir: string
  readonly terminal: TerminalManagerService
  readonly log?: (line: string) => void
  /// Injectable process seam so exit hooks are testable. Production uses the
  /// real `process`.
  readonly processHandle?: {
    readonly on: (event: "exit" | "SIGTERM" | "SIGINT", handler: () => void) => void
    readonly exit: (code: number) => void
  }
}

export interface TerminalPersistence {
  /// Restores the previous process's snapshot into the manager (best-effort:
  /// a missing or corrupt file is skipped) and deletes the file so a later
  /// crash can never resurrect stale buffers twice.
  readonly restore: () => void
  /// Synchronously writes the current buffers (atomic: temp file + rename).
  readonly flush: () => void
  /// Installs flush hooks on every graceful exit path: `process.on("exit")`
  /// covers explicit `process.exit()` (client-requested shutdown, self-update
  /// handoff, startup failure), and SIGTERM/SIGINT handlers convert
  /// signal-driven stops (`codevisor stop`, service managers, Ctrl-C) into
  /// flushing exits with conventional signal exit codes.
  readonly installExitHooks: () => void
}

export const makeTerminalPersistence = (
  options: TerminalPersistenceOptions
): TerminalPersistence => {
  const log = options.log ?? (() => undefined)
  const snapshotPath = join(options.dataDir, SNAPSHOT_FILE)

  const restore = (): void => {
    let raw: string
    try {
      raw = readFileSync(snapshotPath, "utf8")
    } catch {
      return // First boot, or the previous exit was not graceful.
    }
    // Consumed either way: replaying the same snapshot into a future boot
    // after this process crashes would resurrect stale state.
    try {
      unlinkSync(snapshotPath)
    } catch {
      // Removal is best-effort; the next flush overwrites it regardless.
    }
    try {
      const snapshot = JSON.parse(raw) as TerminalSnapshot
      if (snapshot.version !== 1 || !Array.isArray(snapshot.terminals)) return
      options.terminal.restoreTerminals(snapshot)
      if (snapshot.terminals.length > 0) {
        log(`Restored ${snapshot.terminals.length} terminal buffer(s) from previous run`)
      }
    } catch (cause) {
      log(
        `Terminal buffer restore skipped: ${cause instanceof Error ? cause.message : String(cause)}`
      )
    }
  }

  const flush = (): void => {
    try {
      const snapshot = options.terminal.snapshotTerminals()
      if (snapshot.terminals.length === 0) return
      const temporaryPath = `${snapshotPath}.tmp`
      writeFileSync(temporaryPath, JSON.stringify(snapshot), { mode: 0o600 })
      renameSync(temporaryPath, snapshotPath)
    } catch {
      // Never let a persistence failure interfere with shutdown.
    }
  }

  const installExitHooks = (): void => {
    /* v8 ignore next -- tests always inject a handle; production uses the real process. */
    const processHandle = options.processHandle ?? process
    processHandle.on("exit", flush)
    for (const [signal, code] of [
      ["SIGTERM", 143],
      ["SIGINT", 130]
    ] as const) {
      processHandle.on(signal, () => {
        // flush runs via the "exit" handler; exiting here preserves the
        // conventional 128+signal exit code the previous default delivered.
        processHandle.exit(code)
      })
    }
  }

  return { restore, flush, installExitHooks }
}
