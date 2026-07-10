import { describe, expect, it } from "vitest"

import {
  dedentDiffTexts,
  describeCalls,
  diffLineCounts,
  parseResourceLinkUrl,
  resourceLinkLabel,
  toolCallDisplayTitle,
  toolCallDisclosureKey,
  toolGroupDisclosureKey,
  toolGroupSymbol
} from "./ToolGroup"
import type { ToolCallInfo } from "../../lib/session-events"

function call(kind: string): ToolCallInfo {
  return { toolCallId: crypto.randomUUID(), kind, title: "t" }
}

describe("tool call titles", () => {
  it("matches the native fallback for untitled calls", () => {
    expect(toolCallDisplayTitle({ toolCallId: "agent-1", kind: "agent", title: "  " })).toBe(
      "Working…"
    )
  })
})

describe("tool diff rendering", () => {
  it("uses Pierre's parser for fallback line totals", () => {
    expect(diffLineCounts(undefined, "one\ntwo\n")).toEqual({ added: 2, removed: 0 })
    expect(diffLineCounts("keep\nold-a\nold-b\nkeep2\n", "keep\nnew-a\nkeep2\n")).toEqual({
      added: 1,
      removed: 2
    })
    expect(diffLineCounts("x\n", "x\nx\nx\n")).toEqual({ added: 2, removed: 0 })
    expect(diffLineCounts("", "")).toEqual({ added: 0, removed: 0 })
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
    expect(dedented.newText).toBe("first\nthird\n")
  })
})

describe("tool source links", () => {
  it("uses title, then name, then uri as the rendered source label", () => {
    expect(
      resourceLinkLabel({ name: "Docs", title: "Example Docs", uri: "https://example.com" })
    ).toBe("Example Docs")
    expect(resourceLinkLabel({ name: "Docs", uri: "https://example.com" })).toBe("Docs")
    expect(resourceLinkLabel({ name: "", uri: "https://example.com" })).toBe("https://example.com")
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
