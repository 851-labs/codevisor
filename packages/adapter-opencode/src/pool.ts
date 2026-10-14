import type { OpenCodeServer } from "./server.js"

export interface OpenCodeServerLease {
  readonly server: OpenCodeServer
  readonly release: () => void
}

export interface OpenCodeServerPoolOptions {
  readonly idleMs?: number
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
        if (entries.get(key) === held) entries.delete(key)
        throw cause
      }
    },
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
