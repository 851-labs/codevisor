import { describe, expect, it } from "vitest"

import {
  dedentDiffTexts,
  describeCalls,
  diffRows,
  parseResourceLinkUrl,
  resourceLinkLabel,
  toolCallDisclosureKey,
  toolGroupDisclosureKey,
  toolGroupSymbol
} from "./ToolGroup"
import type { ToolCallInfo } from "../../lib/session-events"

function call(kind: string): ToolCallInfo {
  return { toolCallId: crypto.randomUUID(), kind, title: "t" }
}

describe("tool diff rendering", () => {
  it("marks creation diffs as added lines without a phantom trailing line", () => {
    const rows = diffRows(undefined, "one\ntwo\n")

    expect(rows.map((row) => row.kind)).toEqual(["added", "added"])
    expect(rows.map((row) => row.newLine)).toEqual([1, 2])
    expect(rows.every((row) => row.oldLine == null)).toBe(true)
  })

  it("emits replacement removals immediately before additions like macOS", () => {
    const rows = diffRows("keep\nold-a\nold-b\nkeep2\n", "keep\nnew-a\nkeep2\n")

    expect(rows.map((row) => row.kind)).toEqual([
      "context",
      "removed",
      "removed",
      "added",
      "context"
    ])
    expect(rows.map((row) => row.text)).toEqual(["keep", "old-a", "old-b", "new-a", "keep2"])
    expect(rows[3]?.newLine).toBe(2)
    expect(rows[4]?.oldLine).toBe(4)
    expect(rows[4]?.newLine).toBe(3)
  })

  it("counts duplicate line insertions individually", () => {
    const rows = diffRows("x\n", "x\nx\nx\n")

    expect(rows.filter((row) => row.kind === "added")).toHaveLength(2)
    expect(rows.filter((row) => row.kind === "context")).toHaveLength(1)
  })

  it("treats a trailing newline change as context", () => {
    expect(diffRows("a", "a\n").every((row) => row.kind === "context")).toBe(true)
    expect(diffRows("", "")).toEqual([])
  })

  it("dedents shared indentation for rendered edit snippets", () => {
    const dedented = dedentDiffTexts(
      "        if (enabled) {\n          oldCall()\n        }\n",
      "        if (enabled) {\n          newCall()\n        }\n"
    )

    expect(dedented.oldText).toBe("if (enabled) {\n  oldCall()\n}\n")
    expect(dedented.newText).toBe("if (enabled) {\n  newCall()\n}\n")
  })

  it("clears whitespace-only lines that miss the shared prefix", () => {
    const dedented = dedentDiffTexts("    first\n  \n    third\n", "    first\n    third\n")

    expect(dedented.oldText).toBe("first\n\nthird\n")
    expect(diffRows(dedented.oldText, dedented.newText).map((row) => row.text)).toEqual([
      "first",
      "",
      "third"
    ])
  })
})

describe("tool source links", () => {
  it("uses title, then name, then uri as the rendered source label", () => {
    expect(resourceLinkLabel({ name: "Docs", title: "Example Docs", uri: "https://example.com" }))
      .toBe("Example Docs")
    expect(resourceLinkLabel({ name: "Docs", uri: "https://example.com" })).toBe("Docs")
    expect(resourceLinkLabel({ name: "", uri: "https://example.com" })).toBe(
      "https://example.com"
    )
  })

  it("only treats absolute urls as clickable sources", () => {
    expect(parseResourceLinkUrl("https://example.com/docs")?.host).toBe("example.com")
    expect(parseResourceLinkUrl("not a url")).toBeUndefined()
  })
})

describe("tool group summaries", () => {
  it("describes tool groups in first-seen order like macOS", () => {
    expect(describeCalls([call("read"), call("read"), call("read")])).toBe("Read 3 files")
    expect(describeCalls([call("read")])).toBe("Read a file")
    expect(describeCalls([call("search"), call("execute"), call("execute")])).toBe(
      "Searched code and ran 2 commands"
    )
    expect(describeCalls([call("edit")])).toBe("Edited a file")
    expect(describeCalls([call("web_search")])).toBe("Searched the web")
    expect(describeCalls([call("web_search"), call("web_search")])).toBe("Ran 2 web searches")
    expect(describeCalls([call("web_search"), call("fetch")])).toBe(
      "Searched the web and fetched a resource"
    )
    expect(describeCalls([])).toBe("")
  })

  it("uses an Oxford comma for three or more phrases", () => {
    expect(describeCalls([call("read"), call("search"), call("execute")])).toBe(
      "Read a file, searched code, and ran a command"
    )
  })

  it("pins the group icon to the first call like macOS ToolGroupView", () => {
    expect(toolGroupSymbol([call("read"), call("search"), call("search")])).toBe("doc.text")
    expect(toolGroupSymbol([call("search"), call("search"), call("read")])).toBe("magnifyingglass")
    expect(toolGroupSymbol([call("execute")])).toBe("terminal")
    expect(toolGroupSymbol([call("edit")])).toBe("pencil")
    expect(toolGroupSymbol([call("read")])).toBe("doc.text")
    expect(toolGroupSymbol([call("agent")])).toBe("wand.and.sparkles")
  })
})

describe("tool disclosure keys", () => {
  it("uses stable keys matching the macOS transcript disclosure store cases", () => {
    expect(toolGroupDisclosureKey("first-call")).toBe("toolGroup:first-call")
    expect(toolCallDisclosureKey("call-1")).toBe("toolCall:call-1")
  })
})
