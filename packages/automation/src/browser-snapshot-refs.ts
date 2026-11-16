import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import { isRecord } from "./unknown-values.js"

const refPattern = /^e\d+$/

export const routeSnapshotRefs = (
  runtime: BrowserRuntime,
  page: PageHandle,
  args: Readonly<Record<string, unknown>>
): PageHandle => {
  const snapshot = runtime.snapshots.get(page.snapshotKey ?? page.target.targetId)
  const refs = refsIn(args)
  if (snapshot === undefined || refs.length === 0) return page

  const sessions = new Set(refs.map((ref) => snapshot.frames.get(ref) ?? page.sessionId))
  if (sessions.size > 1) {
    throw new Error("These refs are in different frames; act on one frame at a time")
  }
  const [sessionId] = sessions
  if (sessionId === undefined || sessionId === page.sessionId) return page
  return { ...page, sessionId }
}

const refsIn = (args: Readonly<Record<string, unknown>>): string[] => {
  const locator = isRecord(args.locator) ? args.locator : {}
  return [args.target, args.startTarget, args.endTarget, locator.ref].filter(isRef)
}

const isRef = (value: unknown): value is string =>
  typeof value === "string" && refPattern.test(value)
