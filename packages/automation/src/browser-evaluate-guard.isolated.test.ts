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
    "() => [1, 2].map((value) => value * 2)",
    "() => new Date().getFullYear()",
    "() => [...new Set([...document.links].map((link) => link.href))]",
    "() => { let total = 0; for (let index = 0; index < 3; index++) total += index; return total }",
    "() => { let found; found = document.title; return found }",
    "() => { const seen = {}; seen.title = document.title; seen['count']++; delete seen.count; return seen }",
    "() => { const rows = []; for (const row of document.querySelectorAll('tr')) rows.push(row.textContent); return rows }",
    "() => { const query = new URLSearchParams(); query.append('page', '2'); return String(query) }",
    "({ a, b = 1 }, [c, ...rest]) => { a = b; c = rest.length; try { a++ } catch (error) { error = null } return [a, c] }",
    "async () => (await fetch('/api/items')).status",
    "async () => fetch('/api/items', { method: 'get', headers: { accept: 'application/json' } })",
    "(element) => element.scrollIntoView()",
    "() => 'a-b'.replace('-', '+')"
  ])("accepts the read-only function %s", (source) => {
    expect(() => assertReadOnlyFunction(source)).not.toThrow()
  })

  it.each([
    ["() => { document.title = 'x' }", "rejects changing anything but its own local variables"],
    ["() => { counter++ }", "rejects changing anything but its own local variables"],
    [
      "(element) => { element.value = 'x' }",
      "rejects changing anything but its own local variables"
    ],
    [
      "() => { const field = document.querySelector('input'); field.value = 'x' }",
      "rejects changing"
    ],
    ["() => { let field = null; field = document.body; field.hidden = true }", "rejects changing"],
    ["() => { for (const field of document.forms) field.method = 'get' }", "rejects changing"],
    ["() => { const seen = {}; seen.field.value = 'x' }", "rejects changing"],
    ["() => { [location.href] = ['x'] }", "rejects changing"],
    ["() => new Image()", "rejects new Image()"],
    ["() => new window.WebSocket('wss://example.com')", "rejects new WebSocket()"],
    ["() => delete window.name", "rejects delete"],
    ["() => button.click()", "rejects click()"],
    ["() => node['remove']()", "rejects remove()"],
    ["() => document.write('x')", "rejects write()"],
    ["() => localStorage.setItem('a', 'b')", "rejects setItem()"],
    ["() => alert('hi')", "rejects alert()"],
    ["() => location.assign('/next')", "rejects location.assign()"],
    ["() => window.location.reload()", "rejects location.reload()"],
    ["() => fetch('/api', { method: 'POST' })", "rejects fetch() with a method or body"],
    ["() => fetch('/api', { 'body': 'x' })", "rejects fetch() with a method or body"],
    ["() => fetch('/api', options)", "rejects fetch() with a method or body"],
    ["() => fetch('/api', { ...options })", "rejects fetch() with a method or body"],
    ["document.title", "evaluate expects a function"],
    ["() => {", "evaluate expects a JavaScript function: "]
  ])("rejects %s", (source, message) => {
    expect(() => assertReadOnlyFunction(source)).toThrow(message)
  })

  it("points to locators when it refuses a change", () => {
    expect(() => assertReadOnlyFunction("() => button.click()")).toThrow(
      "evaluate is read-only and rejects click(). Act on the page with locators instead."
    )
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
