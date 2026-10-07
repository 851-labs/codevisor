import { describe, expect, it } from "vitest"

import {
  diffStatsFromTexts,
  diffStatsFromUnified,
  lineCount,
  textsFromUnifiedDiff
} from "./diff-stats.js"

describe("diff-stats", () => {
  describe("lineCount", () => {
    it("counts zero lines for an empty string", () => {
      expect(lineCount("")).toBe(0)
    })

    it("does not count a trailing newline as an extra line", () => {
      expect(lineCount("a\nb\n")).toBe(2)
      expect(lineCount("a\nb")).toBe(2)
      expect(lineCount("a")).toBe(1)
    })
  })

  describe("diffStatsFromTexts", () => {
    it("treats a nullish old text as a file creation", () => {
      expect(diffStatsFromTexts("a.txt", undefined, "one\ntwo\n")).toEqual({
        added: 2,
        path: "a.txt",
        removed: 0
      })
    })

    it("reports zero for identical texts", () => {
      expect(diffStatsFromTexts("a.txt", "same\n", "same\n")).toEqual({
        added: 0,
        path: "a.txt",
        removed: 0
      })
    })

    it("counts a full deletion", () => {
      expect(diffStatsFromTexts("a.txt", "one\ntwo\n", "")).toEqual({
        added: 0,
        path: "a.txt",
        removed: 2
      })
    })

    it("counts replaced lines on both sides", () => {
      const oldText = "keep\nold-a\nold-b\nkeep2\n"
      const newText = "keep\nnew-a\nkeep2\n"
      expect(diffStatsFromTexts("a.txt", oldText, newText)).toEqual({
        added: 1,
        path: "a.txt",
        removed: 2
      })
    })

    it("counts duplicate lines individually", () => {
      expect(diffStatsFromTexts("a.txt", "x\n", "x\nx\nx\n")).toEqual({
        added: 2,
        path: "a.txt",
        removed: 0
      })
    })

    it("handles a missing trailing newline change", () => {
      const stats = diffStatsFromTexts("a.txt", "one\ntwo", "one\ntwo\n")
      expect(stats.added).toBeGreaterThanOrEqual(1)
      expect(stats.removed).toBeGreaterThanOrEqual(1)
    })
  })

  describe("diffStatsFromUnified", () => {
    it("ignores headers and hunk markers", () => {
      const unified = [
        "--- a/release.yml",
        "+++ b/release.yml",
        "@@ -13,7 +13,7 @@",
        " macos_runner:",
        "-  description: old",
        "+  description: new",
        "+  required: false",
        " type: string"
      ].join("\n")
      expect(diffStatsFromUnified("release.yml", unified)).toEqual({
        added: 2,
        path: "release.yml",
        removed: 1
      })
    })

    it("counts nothing for an empty diff", () => {
      expect(diffStatsFromUnified("a.txt", "")).toEqual({ added: 0, path: "a.txt", removed: 0 })
    })
  })

  it("rebuilds the old and new text a unified diff shows", () => {
    expect(
      textsFromUnifiedDiff("--- a.txt\n+++ a.txt\n@@ -1,2 +1,2 @@\n alpha\n-beta\n+gamma\n")
    ).toEqual({ oldText: "alpha\nbeta\n", newText: "alpha\ngamma\n" })
    expect(textsFromUnifiedDiff("@@ -0,0 +1 @@\n+new\n")).toEqual({
      oldText: null,
      newText: "new\n"
    })
    // A context line whose leading space was stripped still counts as context.
    expect(textsFromUnifiedDiff("-a\n+b\nplain")).toEqual({
      oldText: "a\nplain\n",
      newText: "b\nplain\n"
    })
    expect(textsFromUnifiedDiff("--- a\n+++ a\n")).toBeUndefined()
  })
})
