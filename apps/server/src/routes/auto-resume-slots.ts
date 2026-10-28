import { swallowError } from "../server-context.js"

export const startingResumesLimit = 4
export const resumeStartTimeoutMs = 2 * 60_000

export interface StartSlots {
  readonly free: () => number
  readonly hold: (sessionId: string) => void
  readonly release: (sessionId: string) => boolean
  readonly close: () => void
}

export const makeStartSlots = (onExpired: () => Promise<void>): StartSlots => {
  const held = new Map<string, ReturnType<typeof setTimeout>>()

  const release = (sessionId: string): boolean => {
    clearTimeout(held.get(sessionId))
    return held.delete(sessionId)
  }

  const expire = (sessionId: string): void => {
    release(sessionId)
    void onExpired().catch(swallowError)
  }

  return {
    free: () => Math.max(0, startingResumesLimit - held.size),
    hold: (sessionId) => {
      release(sessionId)
      const timeout = setTimeout(() => expire(sessionId), resumeStartTimeoutMs)
      timeout.unref()
      held.set(sessionId, timeout)
    },
    release,
    close: () => {
      for (const sessionId of held.keys()) release(sessionId)
    }
  }
}
