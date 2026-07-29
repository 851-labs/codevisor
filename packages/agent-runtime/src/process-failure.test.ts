import { describe, expect, it } from "vitest"
import {
  clampFailureDetail,
  maxFailureDetailLength,
  summarizeProcessFailure
} from "./process-failure.js"

describe("summarizeProcessFailure", () => {
  it("prefers the first Error: line", () => {
    const stderr = [
      "some preamble",
      "Error: Authentication required. Run `cursor-agent login`.",
      "TypeError: later and less relevant"
    ].join("\n")
    expect(summarizeProcessFailure(stderr, "FALLBACK")).toBe(
      "Authentication required. Run `cursor-agent login`."
    )
  })

  it("recognizes prefixed error classes", () => {
    expect(summarizeProcessFailure("TypeError: x is not a function", "FALLBACK")).toBe(
      "x is not a function"
    )
    expect(summarizeProcessFailure("Uncaught Error: boom", "FALLBACK")).toBe("boom")
  })

  it("falls back when output is empty, blank, or pure noise", () => {
    expect(summarizeProcessFailure("", "FALLBACK")).toBe("FALLBACK")
    expect(summarizeProcessFailure("   \n\n  ", "FALLBACK")).toBe("FALLBACK")
    expect(
      summarizeProcessFailure("    at foo (/a.js:1:2)\n    at bar (/b.js:3:4)", "FALLBACK")
    ).toBe("FALLBACK")
    expect(summarizeProcessFailure("\nNode.js v24.5.0\n", "FALLBACK")).toBe("FALLBACK")
  })

  it("uses the first meaningful line when nothing looks like an Error", () => {
    expect(summarizeProcessFailure("cursor-agent: command not found", "FALLBACK")).toBe(
      "cursor-agent: command not found"
    )
  })

  it("drops minified bundle source but keeps long prose", () => {
    const minified = `var u=n("./src/utils/open-browser.ts"),d=function(e,t,n,r){return new(n||(n=Promise))((function(s,i){function a(e){try{c(r.next(e))}catch(e){i(e)}}function o(e){try{c(r.throw(e))}catch(e){i(e)}}}))};const m="CURSOR_AGENT_DISABLE_DEBUG_LOG";let f=null,p=null,A=0,g=[],h=[];`
    expect(minified.length).toBeGreaterThan(180)
    expect(summarizeProcessFailure(`${minified}\nError: real cause`, "FALLBACK")).toBe("real cause")

    // A long, space-rich sentence is a real message, not source.
    const prose = `${"the harness could not start because a required component is missing ".repeat(3)}`
    expect(summarizeProcessFailure(prose, "FALLBACK")).toMatch(/^the harness could not start/)
  })

  it("clamps to a single short line", () => {
    const long = `Error: ${"word ".repeat(200)}`
    const result = summarizeProcessFailure(long, "FALLBACK")
    expect(result.length).toBeLessThanOrEqual(maxFailureDetailLength)
    expect(result).not.toContain("\n")
    expect(result.endsWith("…")).toBe(true)
  })

  it("condenses a real crashed-CLI stderr tail into one sentence", () => {
    // Shape of the captured tail when `cursor-agent` dies at startup because a
    // native module is missing: minified source, the real error, then a deep
    // webpack stack. Only the middle line is useful.
    const tail = [
      `!function(){"use strict";var e={9427:function(e,t,n){${"a".repeat(300)}}}();`,
      "Error: Failed to load native binding for darwin/arm64 (expected: ./merkle-tree-napi.darwin-arm64.node)",
      "Original error: Error: node-loader: cannot open shared object file",
      "    at __webpack_require__ (/opt/homebrew/.../index.js:414:7415283)",
      "    at ../merkle-tree/native.js (/opt/homebrew/.../index.js:414:1473350)",
      "    at ./src/index.tsx (/opt/homebrew/.../index.js:414:9191)",
      "",
      "Node.js v24.5.0"
    ].join("\n")

    expect(summarizeProcessFailure(tail, "cursor-agent exited unexpectedly")).toBe(
      "Failed to load native binding for darwin/arm64 (expected: ./merkle-tree-napi.darwin-arm64.node)"
    )
  })
})

describe("clampFailureDetail", () => {
  it("collapses whitespace and truncates", () => {
    expect(clampFailureDetail("  a   b \n c  ")).toBe("a b c")
    expect(clampFailureDetail("x".repeat(1000))?.length).toBeLessThanOrEqual(maxFailureDetailLength)
  })

  it("returns undefined for blank input", () => {
    expect(clampFailureDetail("")).toBeUndefined()
    expect(clampFailureDetail("   \n  ")).toBeUndefined()
  })
})

describe("generic connection-close substitution", () => {
  // Mirrors the acp.ts probeAuth path: when the SDK reports its placeholder
  // rejection, the child's stderr is what actually explains the failure.
  const isGenericConnectionClose = (message: string): boolean =>
    /^acp connection closed\.?$/i.test(message.trim())

  it("recognizes the SDK placeholder and substitutes stderr", () => {
    expect(isGenericConnectionClose("ACP connection closed")).toBe(true)
    expect(isGenericConnectionClose("  acp connection closed.  ")).toBe(true)
    expect(isGenericConnectionClose("Authentication required")).toBe(false)

    const stderr = "Error: Failed to load native binding for darwin/arm64\n    at req (/a.js:1:2)"
    expect(summarizeProcessFailure(stderr, "ACP connection closed")).toBe(
      "Failed to load native binding for darwin/arm64"
    )
  })

  it("keeps the placeholder when stderr explains nothing", () => {
    expect(summarizeProcessFailure("", "ACP connection closed")).toBe("ACP connection closed")
  })
})

describe("whitespace classification", () => {
  it("counts tabs, not just spaces, when judging a long line", () => {
    // Tab-delimited diagnostic output is prose, not bundle source. Scoring
    // only spaces would rate this 0% whitespace and discard it as minified.
    // Tabs must be interior — leading ones are trimmed before classification.
    const tabbed = "cause\tdetail\t".repeat(20)
    expect(tabbed.length).toBeGreaterThan(180)
    expect(summarizeProcessFailure(tabbed, "FALLBACK")).toMatch(/^cause detail/)
  })
})
