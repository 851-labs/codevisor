import type { Tool } from "@modelcontextprotocol/sdk/types.js"

type SchemaProperties = Readonly<Record<string, object>>

interface ObjectSchema {
  readonly type: "object"
  readonly properties: SchemaProperties
  readonly required?: string[]
  readonly additionalProperties: false
}

export const objectSchema = (
  properties: SchemaProperties = {},
  required: ReadonlyArray<string> = []
): ObjectSchema => ({
  type: "object",
  properties,
  ...(required.length === 0 ? {} : { required: [...required] }),
  additionalProperties: false
})

export const stringProperty = (description: string) => ({ type: "string", description })
export const targetProperties = {
  element: stringProperty("Short human-readable description of the intended element"),
  target: stringProperty("Exact ref (for example e12) from the latest Browser Use snapshot")
}

export const locatorProperty = {
  type: "object",
  description:
    "Playwright-style locator created by machines.current.tools.browser.tab.playwright or supplied as one exact locator descriptor.",
  properties: {
    ref: { type: "string" },
    css: { type: "string" },
    role: { type: "string" },
    name: {
      oneOf: [
        { type: "string" },
        objectSchema({ regex: { type: "string" }, flags: { type: "string" } }, ["regex"])
      ]
    },
    label: {
      oneOf: [
        { type: "string" },
        objectSchema({ regex: { type: "string" }, flags: { type: "string" } }, ["regex"])
      ]
    },
    placeholder: {
      oneOf: [
        { type: "string" },
        objectSchema({ regex: { type: "string" }, flags: { type: "string" } }, ["regex"])
      ]
    },
    text: {
      oneOf: [
        { type: "string" },
        objectSchema({ regex: { type: "string" }, flags: { type: "string" } }, ["regex"])
      ]
    },
    testId: { type: "string" },
    exact: { type: "boolean" },
    scope: { type: "object" },
    frame: { type: "array", items: { type: "string" } },
    filters: { type: "object" },
    index: { oneOf: [{ type: "number" }, { type: "string", enum: ["last"] }] },
    and: { type: "object" },
    or: { type: "object" }
  },
  additionalProperties: false
}

export const locatorSchema = (
  properties: SchemaProperties = {},
  required: ReadonlyArray<string> = []
) =>
  objectSchema(
    {
      locator: locatorProperty,
      timeoutMs: { type: "number", minimum: 0, maximum: 30000 },
      ...properties
    },
    ["locator", ...required]
  )

export const tool = (
  name: string,
  description: string,
  inputSchema: ObjectSchema = objectSchema()
): Tool => ({
  name,
  description,
  inputSchema: {
    ...inputSchema,
    properties: {
      ...inputSchema.properties,
      tabId: { type: "string", description: "Explicit tab ID; never falls back to another tab." }
    }
  }
})

export const tablessTool = (
  name: string,
  description: string,
  inputSchema: ObjectSchema = objectSchema()
): Tool => ({ name, description, inputSchema: { ...inputSchema } })
