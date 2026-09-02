import type { Tool } from "@modelcontextprotocol/sdk/types.js"

const objectSchema = (
  properties: Readonly<Record<string, unknown>> = {},
  required: ReadonlyArray<string> = []
) => ({
  type: "object",
  properties,
  ...(required.length === 0 ? {} : { required }),
  additionalProperties: false
})

const tool = (
  name: string,
  description: string,
  inputSchema: Readonly<Record<string, unknown>> = objectSchema()
): Tool => ({
  name,
  description,
  inputSchema: inputSchema as Tool["inputSchema"]
})

const appProperty = { type: "string", description: "App name, path, or bundle identifier" }
const nativeElementProperty = {
  type: "number",
  description: "Element index from the latest get_app_state result"
}
const windowProperty = {
  type: "number",
  description:
    "windowId from the app state's windows list. Switches the session to that window; omit to stay on the current one."
}
const deliveryProperty = {
  type: "string",
  enum: ["background", "foreground"],
  description:
    "background (default) leaves your app in front; foreground activates the target app first, which is the retry when a background event has no effect."
}

export const computerUseTools: ReadonlyArray<Tool> = [
  tool(
    "list_apps",
    "List installed desktop applications that Computer Use can inspect and control, including whether each app is running."
  ),
  tool(
    "get_app_state",
    "Launch the app if needed, then return its current accessibility text and screenshot. Re-snapshot before each action; element indices are snapshot-scoped.",
    objectSchema(
      {
        app: appProperty,
        window_id: windowProperty,
        disableDiff: {
          type: "boolean",
          description: "Native Computer Use option. true always returns the complete state."
        }
      },
      ["app"]
    )
  ),
  tool(
    "click",
    "Click an accessibility element or screenshot coordinate. Element clicks use an accessibility action when available and otherwise click the element's onscreen frame.",
    {
      type: "object",
      properties: {
        app: appProperty,
        element_index: nativeElementProperty,
        x: { type: "number" },
        y: { type: "number" },
        mouse_button: { type: "string", enum: ["left", "right", "middle", "l", "r", "m"] },
        click_count: { type: "number", minimum: 1, maximum: 2 },
        window_id: windowProperty,
        delivery_mode: deliveryProperty
      },
      required: ["app"],
      additionalProperties: false
    }
  ),
  tool(
    "drag",
    "Drag between two screenshot pixel coordinates.",
    objectSchema(
      {
        app: appProperty,
        from_x: { type: "number" },
        from_y: { type: "number" },
        to_x: { type: "number" },
        to_y: { type: "number" },
        window_id: windowProperty,
        delivery_mode: deliveryProperty
      },
      ["app", "from_x", "from_y", "to_x", "to_y"]
    )
  ),
  tool(
    "perform_secondary_action",
    "Perform an element's named accessibility action.",
    objectSchema(
      {
        app: appProperty,
        element_index: nativeElementProperty,
        action: { type: "string" }
      },
      ["app", "element_index", "action"]
    )
  ),
  tool(
    "press_key",
    "Press a real key or key chord in an app. Return, Tab, Delete, arrows, and modifiers are delivered as native key events.",
    objectSchema(
      {
        app: appProperty,
        key: { type: "string" },
        window_id: windowProperty,
        delivery_mode: deliveryProperty
      },
      ["app", "key"]
    )
  ),
  tool(
    "scroll",
    "Scroll an element or window by pages.",
    objectSchema(
      {
        app: appProperty,
        element_index: nativeElementProperty,
        direction: { type: "string", enum: ["up", "down", "left", "right", "u", "d", "l", "r"] },
        pages: { type: "number" },
        window_id: windowProperty,
        delivery_mode: deliveryProperty
      },
      ["app", "element_index", "direction"]
    )
  ),
  tool(
    "select_text",
    "Select an exact text match in an editable accessibility element, matching native Computer Use. Use prefix or suffix only to disambiguate repeated text. The selected range is preserved for the next formatting or keyboard action.",
    {
      type: "object",
      properties: {
        app: appProperty,
        element_index: nativeElementProperty,
        text: { type: "string", description: "Exact text to select in the editable value" },
        prefix: { type: "string", description: "Require this text immediately before text" },
        suffix: { type: "string", description: "Require this text immediately after text" },
        selection_type: {
          type: "string",
          enum: ["text", "cursor_before", "cursor_after"]
        }
      },
      required: ["app", "element_index", "text"],
      additionalProperties: false
    }
  ),
  tool(
    "set_value",
    "Set an accessibility element's value.",
    objectSchema(
      {
        app: appProperty,
        element_index: nativeElementProperty,
        value: { type: "string" }
      },
      ["app", "element_index", "value"]
    )
  ),
  tool(
    "type_text",
    "Type text into an editable element or the focused control.",
    objectSchema(
      {
        app: appProperty,
        text: { type: "string" },
        window_id: windowProperty,
        delivery_mode: deliveryProperty
      },
      ["app", "text"]
    )
  )
]
