import { parseExpression } from "@babel/parser"
import { afterEach, describe, expect, it, vi } from "vitest"

import { assertReadOnlyFunction } from "./browser-evaluate-guard.js"

vi.mock("@babel/parser", async (original) => {
  const actual = await original<typeof import("@babel/parser")>()
  return { ...actual, parseExpression: vi.fn(actual.parseExpression) }
})

afterEach(() => vi.mocked(parseExpression).mockClear())

describe("assertReadOnlyFunction", () => {
  it.each([
    "() => document.title",
    "function () { return document.querySelectorAll('a').length }",
    "async (selector: string) => document.querySelector(selector)?.getAttribute('href')",
    "() => { const read = (name) => name; return read(element[key]()) }",
    "() => [1, 2].map((value) => value * 2)"
  ])("accepts the read-only function %s", (source) => {
    expect(() => assertReadOnlyFunction(source)).not.toThrow()
  })

  it.each([
    ["() => { document.title = 'x' }", "rejects assignment, update, and construction"],
    ["() => { counter++ }", "rejects assignment, update, and construction"],
    ["() => new Image()", "rejects assignment, update, and construction"],
    ["() => delete window.name", "rejects delete"],
    ["() => button.click()", "rejects click()"],
    ["() => node['remove']()", "rejects remove()"],
    ["() => document.write('x')", "rejects write()"],
    ["document.title", "evaluate expects a function"],
    ["() => {", "evaluate expects a JavaScript function: "]
  ])("rejects %s", (source, message) => {
    expect(() => assertReadOnlyFunction(source)).toThrow(message)
  })

  it("reports a parser failure that is not an Error", () => {
    vi.mocked(parseExpression).mockImplementationOnce(() => {
      throw "parser unavailable"
    })
    expect(() => assertReadOnlyFunction("() => 1")).toThrow(
      "evaluate expects a JavaScript function: parser unavailable"
    )
  })
})
