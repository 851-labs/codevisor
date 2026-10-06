import type { OpenCodeServer } from "./server.js"

/// Control servers shared by everything that needs OpenCode's API for one
/// profile (its catalog, sign-in attempts, credentials): starting one costs
/// a process launch, so a burst of account clicks reuses it, and it stops
/// once nothing has used it for a while.

export interface OpenCodeServerLease {
  readonly server: OpenCodeServer
  /// Hands the server back; the last release starts its idle countdown.
  readonly release: () => void
}

export interface OpenCodeServerPoolOptions {
  readonly idleMs?: number
  /// Runs `run` after `ms` and returns a cancel; injected for tests.
  readonly schedule?: (ms: number, run: () => Promise<void>) => () => void
}

interface Entry {
  readonly server: Promise<OpenCodeServer>
  refs: number
  cancelIdle?: (() => void) | undefined
}

const scheduleTimeout = (ms: number, run: () => Promise<void>) => {
  const timer = setTimeout(() => void run(), ms)
  timer.unref()
  return () => clearTimeout(timer)
}

export const makeOpenCodeServerPool = (options: OpenCodeServerPoolOptions = {}) => {
  const idleMs = options.idleMs ?? 60_000
  const schedule = options.schedule ?? scheduleTimeout
  const entries = new Map<string, Entry>()

  const release = (key: string, entry: Entry) => {
    entry.refs -= 1
    if (entry.refs > 0) return
    entry.cancelIdle = schedule(idleMs, async () => {
      if (entries.get(key) !== entry || entry.refs > 0) return
      entries.delete(key)
      await (await entry.server).stop()
    })
  }

  return {
    /// The running server for `key`, starting it with `start` if none is.
    acquire: async (
      key: string,
      start: () => Promise<OpenCodeServer>
    ): Promise<OpenCodeServerLease> => {
      let entry = entries.get(key)
      if (entry === undefined) {
        entry = { server: start(), refs: 0 }
        entries.set(key, entry)
      }
      const held = entry
      held.refs += 1
      held.cancelIdle?.()
      held.cancelIdle = undefined
      try {
        const server = await held.server
        let released = false
        return {
          server,
          release: () => {
            if (released) return
            released = true
            release(key, held)
          }
        }
      } catch (cause) {
        // A server that failed to start is never reused; the next acquire
        // starts a fresh one.
        if (entries.get(key) === held) entries.delete(key)
        throw cause
      }
    },
    /// Stops every server, for shutdown.
    close: async () => {
      const running = [...entries.values()]
      entries.clear()
      for (const entry of running) entry.cancelIdle?.()
      await Promise.all(
        running.map((entry) => entry.server.then((server) => server.stop()).catch(() => undefined))
      )
    }
  }
}
