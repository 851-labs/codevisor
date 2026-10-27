import { describe, expect, it } from "vitest"

import { patternProblem } from "./event-filter-regex.js"

describe("patternProblem", () => {
  it.each([
    { pattern: String.raw`^Invoice \d+$`, problem: undefined },
    { pattern: "(?:re|fwd): (urgent)?", problem: undefined },
    { pattern: "(ab)+", problem: undefined },
    { pattern: String.raw`[(+*]+\(x\)`, problem: undefined },
    { pattern: String.raw`[\]a-z]+`, problem: undefined },
    { pattern: "(a+)?", problem: undefined },
    { pattern: "((a|b)c)?", problem: undefined },
    { pattern: "re: (a|b)", problem: undefined },
    { pattern: "x".repeat(201), problem: "is longer than 200 characters" },
    { pattern: "(unclosed", problem: "is not a valid regular expression" },
    { pattern: String.raw`(a)\1`, problem: "uses a back-reference" },
    { pattern: String.raw`(?<w>a)\k<w>`, problem: "uses a back-reference" },
    { pattern: "(a+)+$", problem: "repeats a group that itself repeats or alternates" },
    { pattern: "(a|aa)*", problem: "repeats a group that itself repeats or alternates" },
    { pattern: "(a{2,})+", problem: "repeats a group that itself repeats or alternates" },
    { pattern: "((a+)b)*", problem: "repeats a group that itself repeats or alternates" },
    { pattern: "(x(a*)y){3}", problem: "repeats a group that itself repeats or alternates" }
  ])("$pattern", ({ pattern, problem }) => {
    expect(patternProblem(pattern)).toBe(problem)
  })
})
