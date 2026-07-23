import { describe, expect, it } from "vitest"
import { computerUseTools } from "./computer-use-provider.js"

describe("Computer Use tool contract", () => {
  it("keeps the public method and argument surface aligned with native Computer Use", () => {
    const expected = new Map<string, string[]>([
      ["list_apps", []],
      ["get_app_state", ["app", "disableDiff"]],
      ["click", ["app", "element_index", "x", "y", "mouse_button", "click_count"]],
      ["drag", ["app", "from_x", "from_y", "to_x", "to_y"]],
      ["perform_secondary_action", ["app", "element_index", "action"]],
      ["press_key", ["app", "key"]],
      ["scroll", ["app", "element_index", "direction", "pages"]],
      ["select_text", ["app", "element_index", "text", "prefix", "suffix", "selection_type"]],
      ["set_value", ["app", "element_index", "value"]],
      ["type_text", ["app", "text"]]
    ])

    expect(computerUseTools.map((candidate) => candidate.name)).toEqual([...expected.keys()])
    for (const candidate of computerUseTools) {
      const schema = candidate.inputSchema as unknown as {
        properties?: Record<string, unknown>
      }
      expect(Object.keys(schema.properties ?? {})).toEqual(expected.get(candidate.name))
    }
  })

  it("matches the native click call shape", () => {
    const click = computerUseTools.find((candidate) => candidate.name === "click")
    expect(click).toBeDefined()

    const schema = click!.inputSchema as unknown as {
      properties: Record<string, { description?: string; enum?: string[] }>
      required: string[]
      additionalProperties: boolean
    }
    expect(Object.keys(schema.properties)).toEqual([
      "app",
      "element_index",
      "x",
      "y",
      "mouse_button",
      "click_count"
    ])
    expect(schema.properties.mouse_button!.enum).toEqual(["left", "right", "middle", "l", "r", "m"])
    expect(schema.required).toEqual(["app"])
    expect(schema.additionalProperties).toBe(false)
  })

  it("tells agents that element ids are snapshot scoped", () => {
    const state = computerUseTools.find((candidate) => candidate.name === "get_app_state")
    expect(state?.description).toContain("Re-snapshot before each action")
  })

  it("advertises native-style installed app discovery and transparent launching", () => {
    const list = computerUseTools.find((candidate) => candidate.name === "list_apps")
    const state = computerUseTools.find((candidate) => candidate.name === "get_app_state")

    expect(list?.description).toContain("installed desktop applications")
    expect(list?.description).toContain("whether each app is running")
    expect(state?.description).toContain("Launch the app if needed")
  })

  it("matches the native semantic text-selection contract", () => {
    const select = computerUseTools.find((candidate) => candidate.name === "select_text")
    const schema = select?.inputSchema as unknown as {
      additionalProperties: boolean
      properties: Record<string, { enum?: string[] }>
      required: string[]
    }
    expect(schema.properties).not.toHaveProperty("all")
    expect(schema.properties).toHaveProperty("text")
    expect(schema.properties).toHaveProperty("prefix")
    expect(schema.properties).toHaveProperty("suffix")
    expect(schema.properties.selection_type?.enum).toEqual([
      "text",
      "cursor_before",
      "cursor_after"
    ])
    expect(schema.required).toEqual(["app", "element_index", "text"])
    expect(schema.additionalProperties).toBe(false)
  })

  it("does not advertise Codevisor-only action arguments", () => {
    for (const candidate of computerUseTools) {
      const schema = candidate.inputSchema as unknown as {
        properties?: Record<string, unknown>
        additionalProperties?: boolean
      }
      expect(schema.properties ?? {}).not.toHaveProperty("snapshotId")
      expect(schema.properties ?? {}).not.toHaveProperty("elementId")
      expect(schema.properties ?? {}).not.toHaveProperty("deliveryMode")
      expect(schema.additionalProperties).toBe(false)
    }
  })

  it("accepts the native disableDiff option and rejects undeclared arguments", () => {
    const state = computerUseTools.find((candidate) => candidate.name === "get_app_state")
    const schema = state?.inputSchema as unknown as {
      additionalProperties: boolean
      properties: Record<string, unknown>
    }
    expect(schema.properties).toHaveProperty("disableDiff")
    expect(schema.additionalProperties).toBe(false)
  })
})
