import { describe, expect, it } from "vitest"

import type { PageHandle } from "./browser-cdp-engine.js"
import {
  browserToolSessionState,
  fakeBrowserRuntime,
  fakeBrowserToolInvocation,
  fakeCdpConnection
} from "./browser-runtime-test-support.js"
import { snapshotPage, type AXNode } from "./browser-snapshot.js"
import { invokeNavigationTools } from "./browser-use-invoke-navigation.js"

const page: PageHandle = {
  target: { targetId: "tab", type: "page", title: "Rows", url: "https://example.test/" },
  sessionId: "session"
}

const node = (nodeId: string, role: string, name: string, childIds: string[] = []): AXNode => ({
  nodeId,
  ignored: false,
  role: { value: role },
  name: { value: name },
  backendDOMNodeId: Number(nodeId),
  childIds,
  ...(nodeId === "1" ? {} : { parentId: "1" })
})

const rowsPage = (rows: number): AXNode[] => {
  const buttons = Array.from({ length: rows }, (_, index) =>
    node(String(index + 10), "button", `Row ${index + 1}`)
  )
  return [
    node(
      "1",
      "RootWebArea",
      "Rows",
      buttons.map((button) => button.nodeId)
    ),
    ...buttons
  ]
}

const nestedPage = (): AXNode[] => [
  node("1", "RootWebArea", "Nested", ["2", "5"]),
  { ...node("2", "navigation", "Menu", ["3"]), parentId: "1" },
  { ...node("3", "list", "Links", ["4"]), parentId: "2" },
  { ...node("4", "link", "Home"), parentId: "3" },
  { ...node("5", "button", "Outside"), parentId: "1" }
]

const refOf = (line: string) => /\[ref=(e\d+)\]/.exec(line)![1]!

const fixture = (nodes: AXNode[]) => {
  const sent: string[] = []
  const runtime = fakeBrowserRuntime({
    connection: fakeCdpConnection({
      send: async (method) => {
        sent.push(method)
        if (method === "Accessibility.getFullAXTree") return { nodes }
        if (method === "Runtime.evaluate")
          return { result: { value: { url: "https://example.test/", title: "Rows" } } }
        throw new Error(`Unexpected CDP request: ${method}`)
      }
    }).connection
  })
  const snapshot = async (request: { root?: unknown; offset?: unknown; depth?: number } = {}) => {
    const result = await snapshotPage(runtime, page, { depth: 30, ...request })
    const [content] = result.content
    if (content?.type !== "text") throw new Error("Missing snapshot text")
    return content.text.split("\n")
  }
  return { runtime, sent, snapshot }
}

describe("Page snapshot", () => {
  it("shows a long page 2,000 lines at a time and reads on in the same snapshot", async () => {
    const { runtime, sent, snapshot } = fixture(rowsPage(2500))

    const first = await snapshot()
    expect(first.slice(3, 5)).toEqual([
      '- RootWebArea "Rows"',
      expect.stringMatching(/^ {2}- button "Row 1" \[ref=e\d+\]$/)
    ])
    expect(first).toHaveLength(2004)
    expect(first.at(-1)).toBe(
      "[Lines 1-2000 of 2501. Read on with tab.getAXState({ offset: 2000 }); the refs above stay valid. Or show one part of the page with tab.getAXState({ root }), where root is a ref or a locator.]"
    )

    const treeReads = sent.filter((method) => method === "Accessibility.getFullAXTree").length
    const second = await snapshot({ offset: 2000 })
    expect(second[1]).toBe(first[1])
    expect(second[3]).toMatch(/- button "Row 2000" \[ref=e\d+\]/)
    expect(second.at(-2)).toMatch(/- button "Row 2500" \[ref=e\d+\]/)
    expect(second.at(-1)).toBe("[Lines 2001-2501 of 2501; end of the snapshot.]")
    expect(sent.filter((method) => method === "Accessibility.getFullAXTree")).toHaveLength(
      treeReads
    )

    const refs = runtime.snapshots.get("tab")!.targets
    expect(refs.get(refOf(first[4]!))).toBe(10)
    expect(refs.get(refOf(second.at(-2)!))).toBe(2509)
  })

  it("adds nothing to a page that fits", async () => {
    const { snapshot } = fixture(rowsPage(2))
    expect((await snapshot()).slice(3)).toEqual([
      '- RootWebArea "Rows"',
      expect.stringContaining('button "Row 1"'),
      expect.stringContaining('button "Row 2"')
    ])
  })

  it("refuses an offset that is malformed, past the end, or from a page that has changed", async () => {
    const { runtime, snapshot } = fixture(rowsPage(2500))
    await snapshot()
    await expect(snapshot({ offset: "2000" })).rejects.toThrow("offset must be a line count")
    await expect(snapshot({ offset: 2501 })).rejects.toThrow(
      "offset 2501 is past the end of the snapshot, which has 2501 lines"
    )
    runtime.snapshots.clear()
    await expect(snapshot({ offset: 2000 })).rejects.toThrow(
      "The page changed since the last snapshot"
    )
  })

  it("captures one part of the page under a ref, and retires the earlier refs", async () => {
    const { runtime, snapshot } = fixture(nestedPage())
    const whole = await snapshot()
    const menu = /navigation "Menu" \[ref=(e\d+)\]/.exec(whole.join("\n"))![1]!

    const part = await snapshot({ root: menu })
    expect(part.slice(3)).toEqual([
      expect.stringMatching(/^- navigation "Menu" \[ref=e\d+\]$/),
      expect.stringMatching(/^ {2}- list "Links" \[ref=e\d+\]$/),
      expect.stringMatching(/^ {4}- link "Home" \[ref=e\d+\]$/)
    ])
    expect(runtime.snapshots.get("tab")!.targets.has(menu)).toBe(false)
    await expect(snapshot({ root: menu })).rejects.toThrow(`Unknown or stale root ${menu}`)
  })

  it("says when levels were left out and how to see them", async () => {
    const { snapshot } = fixture(nestedPage())
    const shallow = await snapshot({ depth: 1 })
    expect(shallow.join("\n")).not.toContain('link "Home"')
    expect(shallow.at(-1)).toMatch(/^\[Some of the page was left out: it is nested too deeply/)
  })
})

describe("Full-page screenshot", () => {
  it("names the page size and the way round it when the browser can't capture it", async () => {
    const runtime = fakeBrowserRuntime({
      connection: fakeCdpConnection({
        send: async (method) => {
          if (method === "Page.getLayoutMetrics")
            return { contentSize: { x: 0, y: 0, width: 1440, height: 250_000.4 } }
          if (method === "Runtime.evaluate") return { result: { value: false } }
          throw new Error("Unable to capture screenshot")
        }
      }).connection
    })
    const capture = (args: Record<string, unknown>) =>
      invokeNavigationTools(
        fakeBrowserToolInvocation({ active: runtime, page, toolName: "screenshot", args }),
        browserToolSessionState()
      )

    await expect(capture({ fullPage: true })).rejects.toThrow(
      "The whole page is 1440 x 250000 px, too large for the browser to capture as one image. Capture it in parts with tab.screenshot({ clip: { x, y, width, height } }), or read it with tab.getAXState()."
    )
    await expect(capture({ clip: { x: 0, y: 0, width: 10, height: 10 } })).rejects.toThrow(
      "Unable to capture screenshot"
    )
  })
})
