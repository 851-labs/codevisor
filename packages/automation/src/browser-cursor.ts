import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { delay } from "./browser-cdp.js"
import {
  pointerOverlayExpression,
  type PointerCommand,
  type PointerReply
} from "./browser-cursor-overlay.js"

export interface BrowserCursor {
  readonly move: (x: number, y: number) => Promise<void>
  readonly track: (x: number, y: number) => Promise<void>
  readonly pulse: (x: number, y: number) => Promise<void>
}

export interface BrowserCursorIdentity {
  readonly session: string
  readonly color: number
  readonly side: 1 | -1
}

export interface BrowserCursorRegistry {
  readonly cursorFor: (
    runtime: BrowserRuntime,
    page: PageHandle,
    sessionKey: string
  ) => BrowserCursor
  readonly release: (sessionKey: string) => void
}

export const BROWSER_CURSOR_PALETTE_COUNT = 8

const fnv1a = (text: string): number => {
  let hash = 0x811c9dc5
  for (const character of text) {
    hash ^= character.codePointAt(0)!
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  return hash >>> 0
}

export const cursorColorIndex = (
  sessionKey: string,
  taken: ReadonlySet<number>,
  paletteCount = BROWSER_CURSOR_PALETTE_COUNT
): number => {
  const start = fnv1a(sessionKey) % paletteCount
  for (let probe = 0; probe < paletteCount; probe++) {
    const candidate = (start + probe) % paletteCount
    if (!taken.has(candidate)) return candidate
  }
  return start
}

export const browserCursorEnabled = (env: NodeJS.ProcessEnv = process.env): boolean =>
  env.CODEVISOR_BROWSER_CURSOR !== "0"

const isPointerReply = (value: unknown): value is PointerReply =>
  typeof value === "object" &&
  value !== null &&
  typeof (value as { duration?: unknown }).duration === "number" &&
  typeof (value as { visible?: unknown }).visible === "boolean"

const MAX_WAIT_MS = 700
const ACKNOWLEDGE_TIMEOUT_MS = 1_500

export const makeBrowserCursor = (
  runtime: BrowserRuntime,
  page: PageHandle,
  identity: BrowserCursorIdentity,
  enabled = browserCursorEnabled()
): BrowserCursor => {
  const send = async (
    command: Omit<PointerCommand, "session" | "color" | "side">
  ): Promise<PointerReply | undefined> => {
    if (!enabled || runtime.dialogs.has(page.sessionId)) return undefined
    try {
      const response = await Promise.race([
        runtime.connection.send<{ result?: { value?: unknown } }>(
          "Runtime.evaluate",
          {
            expression: pointerOverlayExpression({ ...identity, ...command }),
            returnByValue: true
          },
          page.sessionId
        ),
        delay(ACKNOWLEDGE_TIMEOUT_MS).then(() => undefined)
      ])
      const value = response?.result?.value
      return isPointerReply(value) ? value : undefined
    } catch {
      return undefined
    }
  }
  return {
    move: async (x, y) => {
      const reply = await send({ kind: "move", x, y })
      if (reply !== undefined && reply.duration > 0)
        await delay(Math.min(MAX_WAIT_MS, reply.duration))
    },
    track: async (x, y) => {
      await send({ kind: "track", x, y })
    },
    pulse: async (x, y) => {
      await send({ kind: "pulse", x, y })
    }
  }
}

export const makeBrowserCursorRegistry = (): BrowserCursorRegistry => {
  const identities = new Map<string, BrowserCursorIdentity>()
  const identityFor = (sessionKey: string): BrowserCursorIdentity => {
    const existing = identities.get(sessionKey)
    if (existing !== undefined) return existing
    const taken = new Set([...identities.values()].map((identity) => identity.color))
    const hash = fnv1a(sessionKey)
    const identity: BrowserCursorIdentity = {
      session: hash.toString(36),
      color: cursorColorIndex(sessionKey, taken),
      side: (hash & 1) === 0 ? 1 : -1
    }
    identities.set(sessionKey, identity)
    return identity
  }
  return {
    cursorFor: (runtime, page, sessionKey) =>
      makeBrowserCursor(runtime, page, identityFor(sessionKey)),
    release: (sessionKey) => {
      identities.delete(sessionKey)
    }
  }
}
