import { parseExpression } from "@babel/parser"
import { describe, expect, it, vi } from "vitest"
import type { BrowserRuntime, PageHandle } from "./browser-cdp-engine.js"
import {
  BROWSER_CURSOR_PALETTE_COUNT,
  cursorColorIndex,
  fnv1a,
  makeBrowserCursor,
  makeBrowserCursorRegistry,
  pointerOverlayExpression,
  pointerOverlaySource
} from "./browser-cursor.js"

const page: PageHandle = {
  target: { targetId: "tab", type: "page", title: "", url: "about:blank" },
  sessionId: "tab:1"
}

const fakeRuntime = (
  handler: (method: string, params: Readonly<Record<string, unknown>>) => unknown
): { runtime: BrowserRuntime; calls: Array<{ method: string; expression: string }> } => {
  const calls: Array<{ method: string; expression: string }> = []
  const runtime = {
    dialogs: new Map<string, Readonly<Record<string, unknown>>>(),
    connection: {
      send: async (method: string, params: Readonly<Record<string, unknown>>) => {
        calls.push({ method, expression: String(params.expression) })
        return handler(method, params)
      }
    }
  } as unknown as BrowserRuntime
  return { runtime, calls }
}

describe("browser cursor presentation", () => {
  it("ships the page overlay as a self-contained function expression", () => {
    expect(() => parseExpression(pointerOverlaySource)).not.toThrow()
    expect(pointerOverlaySource).not.toContain("import(")
    expect(pointerOverlaySource).not.toContain("innerHTML")
    // Without a document (Node), the overlay reports an idle reply instead of throwing.
    const overlay = new Function(`return (${pointerOverlaySource})`)() as (
      command: unknown
    ) => unknown
    expect(overlay({ kind: "move", session: "a", x: 1, y: 2 })).toEqual({
      duration: 0,
      visible: false
    })
  })

  it("serializes commands into the evaluated expression", () => {
    const expression = pointerOverlayExpression({ kind: "pulse", session: "abc", x: 10, y: 20 })
    expect(expression.startsWith(`(${pointerOverlaySource})(`)).toBe(true)
    expect(expression.endsWith(`)({"kind":"pulse","session":"abc","x":10,"y":20})`)).toBe(true)
  })

  it("assigns stable palette slots that avoid concurrently active colors", () => {
    const hash = fnv1a("extension:session-a")
    expect(hash).toBe(fnv1a("extension:session-a"))
    const first = cursorColorIndex("extension:session-a", new Set())
    expect(first).toBe(hash % BROWSER_CURSOR_PALETTE_COUNT)
    expect(cursorColorIndex("extension:session-a", new Set([first]))).toBe(
      (first + 1) % BROWSER_CURSOR_PALETTE_COUNT
    )
    const everyColor = new Set(
      Array.from({ length: BROWSER_CURSOR_PALETTE_COUNT }, (_, index) => index)
    )
    expect(cursorColorIndex("extension:session-a", everyColor)).toBe(first)
  })

  it("keeps one identity per session and frees it on release", () => {
    const registry = makeBrowserCursorRegistry()
    const { runtime, calls } = fakeRuntime(() => ({
      result: { value: { duration: 0, visible: true } }
    }))
    const a = registry.cursorFor(runtime, page, "extension:a")
    const b = registry.cursorFor(runtime, page, "extension:b")
    return Promise.all([
      a.track(1, 1),
      b.track(2, 2),
      registry.cursorFor(runtime, page, "extension:a").track(3, 3)
    ]).then(() => {
      const identities = calls.map((call) => {
        const match = call.expression.match(/\)\((\{.*\})\)$/)
        return JSON.parse(match![1]!) as { session: string; color: number }
      })
      expect(identities[0]!.session).toBe(identities[2]!.session)
      expect(identities[0]!.color).not.toBe(identities[1]!.color)
      registry.release("extension:a")
      registry.release("extension:b")
      // Once both are released, the next session may reuse either color again.
      return registry
        .cursorFor(runtime, page, "extension:b")
        .track(0, 0)
        .then(() => {
          const reused = JSON.parse(calls.at(-1)!.expression.match(/\)\((\{.*\})\)$/)![1]!) as {
            color: number
          }
          expect(reused.color).toBe(cursorColorIndex("extension:b", new Set()))
        })
    })
  })

  it("waits for the page-reported travel before returning from move", async () => {
    const { runtime, calls } = fakeRuntime(() => ({
      result: { value: { duration: 120, visible: true } }
    }))
    const cursor = makeBrowserCursor(runtime, page, { session: "s", color: 1, side: 1 }, true)
    const started = Date.now()
    await cursor.move(40, 50)
    expect(Date.now() - started).toBeGreaterThanOrEqual(100)
    expect(calls).toHaveLength(1)
    expect(calls[0]!.method).toBe("Runtime.evaluate")
    expect(calls[0]!.expression).toContain('"kind":"move"')
    expect(calls[0]!.expression).toContain('"x":40,"y":50')
  })

  it("proceeds without the cursor when the page never acknowledges the draw", async () => {
    vi.useFakeTimers()
    try {
      const { runtime, calls } = fakeRuntime(() => new Promise(() => undefined))
      const cursor = makeBrowserCursor(runtime, page, { session: "s", color: 1, side: 1 }, true)
      const move = cursor.move(5, 6)
      await vi.advanceTimersByTimeAsync(2_000)
      await expect(move).resolves.toBeUndefined()
      expect(calls).toHaveLength(1)
    } finally {
      vi.useRealTimers()
    }
  })

  it("never lets a drawing failure block the action", async () => {
    const { runtime, calls } = fakeRuntime(() => {
      throw new Error("Cannot find context with specified id")
    })
    const cursor = makeBrowserCursor(runtime, page, { session: "s", color: 1, side: 1 }, true)
    await expect(cursor.move(1, 2)).resolves.toBeUndefined()
    await expect(cursor.pulse(1, 2)).resolves.toBeUndefined()
    expect(calls).toHaveLength(2)
  })

  it("stays out of the way while a dialog is open or when disabled", async () => {
    const { runtime, calls } = fakeRuntime(() => ({ result: { value: {} } }))
    runtime.dialogs.set(page.sessionId, { type: "alert" })
    await makeBrowserCursor(runtime, page, { session: "s", color: 1, side: 1 }, true).move(1, 2)
    runtime.dialogs.clear()
    await makeBrowserCursor(runtime, page, { session: "s", color: 1, side: 1 }, false).move(1, 2)
    expect(calls).toHaveLength(0)
  })
})
