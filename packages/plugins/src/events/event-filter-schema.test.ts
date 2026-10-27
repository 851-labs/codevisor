import { describe, expect, it } from "vitest"

import { messageContext } from "./event-filter-test-support.js"
import { compileEventFilter } from "./index.js"

const matches = (expression: string, schema: unknown, payload: unknown): boolean => {
  const result = compileEventFilter(expression, schema)
  if (!result.ok) throw new Error(result.error)
  return result.filter.matches(payload, messageContext)
}

const errorFor = (expression: string, schema: unknown): string | undefined => {
  const result = compileEventFilter(expression, schema)
  return result.ok ? undefined : result.error
}

const nestedSchema = (depth: number): unknown =>
  depth === 0 ? { type: "integer" } : { properties: { a: nestedSchema(depth - 1) } }

const nestedValue = (depth: number): unknown => (depth === 0 ? 1 : { a: nestedValue(depth - 1) })

const shapesSchema = {
  type: "object",
  properties: {
    retries: { type: ["integer", "null"] },
    mixed: { type: ["string", "integer"] },
    meta: { properties: { origin: { properties: { region: { type: "string" } } } } },
    tags: { type: "array" },
    owner: { type: ["object", "null"], properties: { id: { type: "string" } } },
    matrix: { type: "array", items: { type: "array", items: { type: "integer" } } },
    counts: { type: "object", additionalProperties: { type: "integer" } },
    loose: { type: "object" },
    anything: true
  }
}

describe("compileEventFilter payload schemas", () => {
  it.each([
    { expression: "retries == 2 && mixed == 4", payload: { retries: 2, mixed: 4 }, matches: true },
    { expression: "retries == null", payload: { retries: null }, matches: true },
    {
      expression: 'meta.origin.region == "eu"',
      payload: { meta: { origin: { region: "eu" } } },
      matches: true
    },
    { expression: '"a" in tags', payload: { tags: ["a", 1] }, matches: true },
    { expression: '"a" in tags', payload: { tags: "a" }, matches: false },
    { expression: "owner == null", payload: { owner: null }, matches: true },
    { expression: 'owner.id == "u1"', payload: { owner: { id: "u1" } }, matches: true },
    { expression: "matrix[0][1] == 2", payload: { matrix: [[1, 2]] }, matches: true },
    { expression: "counts.open > 1", payload: { counts: { open: 3 } }, matches: true },
    { expression: 'loose.kind == "x"', payload: { loose: { kind: "x" } }, matches: true },
    {
      expression: "anything.deep.value == 3",
      payload: { anything: { deep: { value: 3 } } },
      matches: true
    }
  ])("$expression → $matches", ({ expression, payload, matches: expected }) => {
    expect(matches(expression, shapesSchema, payload)).toBe(expected)
  })

  it("rejects unknown keys on nested records", () => {
    expect(errorFor('meta.origin.zone == "x"', shapesSchema)).toBe('No such key: zone in "zone".')
  })

  it("falls back to dyn below the schema depth cap", () => {
    expect(matches("a.a.a.a.a.a.a.a.a.a.a == 1", nestedSchema(11), nestedValue(11))).toBe(true)
  })

  it("skips fields that are not usable CEL variables", () => {
    const schema = {
      properties: {
        "content-type": { type: "string" },
        type: { type: "string" },
        ok: { type: "boolean" }
      }
    }
    expect(errorFor("nope", schema)).toBe('Unknown variable: nope in "nope". Fields: ok, event.')
    expect(matches("ok", schema, { "content-type": "text/plain", type: "push", ok: true })).toBe(
      true
    )
  })

  it("lets a payload field named event replace the event variable", () => {
    const schema = { properties: { event: { type: "string" } } }
    expect(matches('event == "push"', schema, { event: "push" })).toBe(true)
    expect(errorFor("nope", schema)).toBe('Unknown variable: nope in "nope". Fields: event.')
  })
})

describe("compileEventFilter without a typed payload", () => {
  it.each([
    undefined,
    true,
    "string",
    { type: "object" },
    { type: ["object", "null"], properties: { id: {} } }
  ])("treats fields as dyn for schema %j", (schema) => {
    expect(matches('kind == "push" && count == 3', schema, { kind: "push", count: 3 })).toBe(true)
    expect(matches('kind == "push"', schema, { kind: "pull" })).toBe(false)
  })

  it("keeps event metadata authoritative over a payload key named event", () => {
    expect(matches('event.name == "message.received"', undefined, { event: "spoof" })).toBe(true)
  })

  it("still evaluates event metadata when the payload is not an object", () => {
    expect(matches('event.eventId == "18c0f"', undefined, "raw text")).toBe(true)
  })

  it("normalizes integer map values", () => {
    expect(
      matches(
        "open == 3",
        { additionalProperties: { type: "integer" }, type: "object" },
        { open: 3 }
      )
    ).toBe(true)
  })

  it("rejects a bare dyn result", () => {
    expect(errorFor("kind", undefined)).toBe("Filter must be true or false, but it gives dyn.")
  })
})
