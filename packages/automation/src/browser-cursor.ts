import { delay } from "./browser-cdp.js"
import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import {
  pointerOverlayExpression,
  type PointerCommand,
  type PointerReply
} from "./browser-cursor-overlay.js"

export {
  pointerOverlayExpression,
  pointerOverlaySource,
  type PointerCommand,
  type PointerReply
} from "./browser-cursor-overlay.js"

/**
 * Browser Use cursor presentation.
 *
 * Computer Use draws an animated pointer over native apps so a person can follow what an agent is
 * doing. Browser Use has no native window to draw into: both the managed Chromium and the user's
 * Chrome (through the relay extension) are only reachable over CDP. So the pointer is drawn by
 * the page itself. Every pointer action evaluates a self-contained script in the tab that owns a
 * fixed, pointer-events-free overlay and animates an arrow to the action point. The server waits
 * for the arc to land before dispatching the trusted CDP mouse event, then asks for the click
 * pulse afterwards, mirroring the ordering ComputerUsePresentation uses on macOS.
 *
 * Everything here is cosmetic. Any failure to draw is swallowed so it can never break an action.
 */

export interface BrowserCursor {
  /** Animate the pointer to a viewport point and resolve once it has arrived. */
  readonly move: (x: number, y: number) => Promise<void>
  /** Reposition the pointer immediately, for following a drag path. */
  readonly track: (x: number, y: number) => Promise<void>
  /** Play the click pulse at a viewport point. */
  readonly pulse: (x: number, y: number) => Promise<void>
}

export interface BrowserCursorIdentity {
  /** Short opaque id used to key the pointer inside the page. */
  readonly session: string
  readonly color: number
  /** Which side of the straight line the travel arc bulges toward. */
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

export const fnv1a = (text: string): number => {
  let hash = 0x811c9dc5
  for (const character of text) {
    hash ^= character.codePointAt(0)!
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  return hash >>> 0
}

/**
 * Deterministic per-session palette slot, probing forward past colors that concurrently active
 * sessions already own so two agents on the same page never share a pointer color.
 */
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

/** Longest the server will pace an action behind the cursor before proceeding regardless. */
const MAX_WAIT_MS = 700
/** How long to wait for the page to acknowledge a draw command before proceeding without it. */
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
    // A modal JavaScript dialog suspends Runtime.evaluate; drawing would hang the action.
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
