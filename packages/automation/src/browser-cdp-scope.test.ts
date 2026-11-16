import { describe, expect, it } from "vitest"

import type { PageHandle } from "./browser-cdp-engine.js"
import {
  requireTabScopedCommand,
  tabScopedEventSession,
  tabScopedResult,
  tabScopedSession
} from "./browser-cdp-scope.js"

const page: PageHandle = {
  target: { targetId: "tab", type: "page", title: "Tab", url: "https://example.test/" },
  sessionId: "tab-session"
}

const runtime = {
  sessions: new Map([
    ["tab", "tab-session"],
    ["frame", "frame-session"],
    ["nested", "nested-session"],
    ["other-tab", "other-session"],
    ["other-frame", "other-frame-session"]
  ]),
  frameParents: new Map([
    ["frame-session", "tab-session"],
    ["nested-session", "frame-session"],
    ["other-frame-session", "other-session"]
  ]),
  staleSessions: new Map([
    ["old-session", "tab"],
    ["old-other-session", "other-tab"]
  ])
}

const outside = /isn't this tab or one of its cross-site frames/

describe("Raw CDP tab scope", () => {
  it("sends to the tab unless one of its frames is named", () => {
    expect(tabScopedSession(runtime, page, undefined)).toBe("tab-session")
    expect(tabScopedSession(runtime, page, "tab")).toBe("tab-session")
    expect(tabScopedSession(runtime, page, "frame")).toBe("frame-session")
    expect(tabScopedSession(runtime, page, { targetId: "frame" })).toBe("frame-session")
    expect(tabScopedSession(runtime, page, { frameId: "nested" })).toBe("nested-session")
    expect(tabScopedSession(runtime, page, { sessionId: "nested-session" })).toBe("nested-session")
  })

  it.each(["other-tab", "other-frame", "other-session", "old-session", "unknown"])(
    "refuses to send to %s",
    (target) => {
      expect(() => tabScopedSession(runtime, page, target)).toThrow(outside)
      expect(() => tabScopedSession(runtime, page, { targetId: target })).toThrow(outside)
      expect(() => tabScopedSession(runtime, page, { sessionId: target })).toThrow(outside)
    }
  )

  it.each([7, {}, { targetId: 7 }, ["frame"]])("rejects the malformed target %j", (target) => {
    expect(() => tabScopedSession(runtime, page, target)).toThrow(/target must be/)
  })

  it("reads events from the tab's own closed sessions but not another tab's", () => {
    expect(tabScopedEventSession(runtime, page, undefined)).toBe("tab-session")
    expect(tabScopedEventSession(runtime, page, "frame")).toBe("frame-session")
    expect(tabScopedEventSession(runtime, page, { sessionId: "old-session" })).toBe("old-session")
    expect(() => tabScopedEventSession(runtime, page, "old-other-session")).toThrow(outside)
    expect(() => tabScopedEventSession(runtime, page, "other-tab")).toThrow(outside)
  })

  it("refuses commands that act on the whole browser or on Codevisor's own sessions", () => {
    for (const method of ["Browser.close", "Target.createTarget", "Target.setDiscoverTargets"])
      expect(() => requireTabScopedCommand(runtime, page, method, {})).toThrow(
        `${method} acts on the whole browser`
      )
    for (const method of ["Target.attachToTarget", "Target.setAutoAttach"])
      expect(() => requireTabScopedCommand(runtime, page, method, { targetId: "frame" })).toThrow(
        `${method} isn't available`
      )
  })

  it("refuses commands that hand the page files by path", () => {
    expect(() =>
      requireTabScopedCommand(runtime, page, "DOM.setFileInputFiles", { files: ["/etc/hosts"] })
    ).toThrow("DOM.setFileInputFiles hands the page files by path")
    expect(() =>
      requireTabScopedCommand(runtime, page, "Input.dispatchDragEvent", {
        type: "drop",
        data: { items: [], files: ["/etc/hosts"] }
      })
    ).toThrow("Input.dispatchDragEvent hands the page files by path")
    requireTabScopedCommand(runtime, page, "Input.dispatchDragEvent", {
      type: "dragOver",
      data: { items: [{ mimeType: "text/plain", data: "card" }], files: [] }
    })
  })

  it("lets target commands name only the tab and its frames", () => {
    requireTabScopedCommand(runtime, page, "Target.getTargetInfo", {})
    requireTabScopedCommand(runtime, page, "Target.getTargetInfo", { targetId: "nested" })
    requireTabScopedCommand(runtime, page, "Target.closeTarget", { targetId: "tab" })
    requireTabScopedCommand(runtime, page, "DOM.describeNode", { targetId: "other-tab" })
    expect(() =>
      requireTabScopedCommand(runtime, page, "Target.closeTarget", { targetId: "other-tab" })
    ).toThrow(outside)
    expect(() =>
      requireTabScopedCommand(runtime, page, "Target.activateTarget", { targetId: "other-frame" })
    ).toThrow(outside)
  })

  it("lists only the tab and its frames as targets", () => {
    const listed = {
      targetInfos: ["tab", "frame", "nested", "other-tab", "other-frame", "extension"].map(
        (targetId) => ({ targetId })
      )
    }
    expect(tabScopedResult(runtime, page, "Target.getTargets", listed)).toEqual({
      targetInfos: [{ targetId: "tab" }, { targetId: "frame" }, { targetId: "nested" }]
    })
    expect(tabScopedResult(runtime, page, "Runtime.evaluate", listed)).toBe(listed)
  })
})
