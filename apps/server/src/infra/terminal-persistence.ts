import { readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { TerminalServerFrame } from "@codevisor/api"
import type { TerminalManagerService } from "@codevisor/terminal"
import { Schema } from "effect"

const SNAPSHOT_FILE = "terminal-buffers.json"
export const PERIODIC_FLUSH_INTERVAL_MS = 30_000

const TerminalSnapshot = Schema.Struct({
  version: Schema.Literals([1, 2, 3]),
  terminals: Schema.Array(
    Schema.Struct({
      terminalId: Schema.String,
      sessionId: Schema.String,
      nextOutputSeq: Schema.Number,
      closed: Schema.Boolean,
      external: Schema.Boolean,
      screen: Schema.optionalKey(Schema.String),
      cols: Schema.optionalKey(Schema.Number),
      rows: Schema.optionalKey(Schema.Number),
      exitCode: Schema.optionalKey(Schema.Number),
      frames: Schema.optionalKey(Schema.Array(TerminalServerFrame))
    })
  )
})
const isTerminalSnapshot = Schema.is(TerminalSnapshot)

export interface TerminalPersistenceOptions {
  readonly dataDir: string
  readonly terminal: TerminalManagerService
  readonly log?: (line: string) => void
  readonly onRestoreProgress?: (completed: number, total: number) => void
  readonly processHandle?: {
    readonly on: (event: "exit" | "SIGTERM" | "SIGINT", handler: () => void) => void
    readonly exit: (code: number) => void
  }
  readonly setInterval?: (run: () => void, ms: number) => { unref?: () => void }
}

export interface TerminalPersistence {
  readonly restore: () => void
  readonly flush: () => void
  readonly installExitHooks: () => void
  readonly startPeriodicFlush: () => void
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
      return
    }
    try {
      unlinkSync(snapshotPath)
    } catch {}
    try {
      const snapshot: unknown = JSON.parse(raw)
      if (!isTerminalSnapshot(snapshot)) return
      const total = snapshot.terminals.length
      options.onRestoreProgress?.(0, total)
      for (let index = 0; index < total; index += 32) {
        options.terminal.restoreTerminals({
          version: snapshot.version,
          terminals: snapshot.terminals.slice(index, index + 32)
        })
        options.onRestoreProgress?.(Math.min(index + 32, total), total)
      }
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
    } catch {}
  }

  let flushedRevision: number | undefined
  const startPeriodicFlush = (): void => {
    /* v8 ignore next */
    const schedule = options.setInterval ?? ((run: () => void, ms: number) => setInterval(run, ms))
    const timer = schedule(() => {
      const revision = options.terminal.outputRevision()
      if (revision === flushedRevision) return
      flushedRevision = revision
      flush()
    }, PERIODIC_FLUSH_INTERVAL_MS)
    timer.unref?.()
  }

  const installExitHooks = (): void => {
    /* v8 ignore next */
    const processHandle = options.processHandle ?? process
    processHandle.on("exit", flush)
    for (const [signal, code] of [
      ["SIGTERM", 143],
      ["SIGINT", 130]
    ] as const) {
      processHandle.on(signal, () => {
        processHandle.exit(code)
      })
    }
  }

  return { restore, flush, installExitHooks, startPeriodicFlush }
}
