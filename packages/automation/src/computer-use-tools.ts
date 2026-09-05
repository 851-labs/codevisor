import type { Tool } from "@modelcontextprotocol/sdk/types.js"

const objectSchema = (properties: Record<string, unknown> = {}, required: string[] = []) => ({
  type: "object",
  properties,
  ...(required.length === 0 ? {} : { required }),
  additionalProperties: false
})
const tool = (
  name: string,
  description: string,
  properties = {},
  required: string[] = []
): Tool => ({
  name,
  description,
  inputSchema: objectSchema(properties, required) as Tool["inputSchema"]
})
const app = { type: "string", description: "App name, path, or bundle identifier" }
const element = {
  type: "integer",
  minimum: 0,
  description: "Element index from an observation of this app and window"
}
const window = { type: "integer", description: "windowId from the observed windows list" }
const snapshot = {
  type: "string",
  description:
    "snapshotId that supplied this element or screenshot; stale or mismatched snapshots are rejected"
}
const delivery = {
  type: "string",
  enum: ["background", "foreground"],
  description:
    "background (default) uses targeted input. foreground activates the app and keeps it in front for subsequent actions."
}
const target = {
  app,
  window_id: window,
  snapshot_id: snapshot,
  element_index: element,
  delivery_mode: delivery
}
const point = {
  type: "number",
  minimum: 0,
  description: "Pixel coordinate inside the observed screenshot"
}
const view = {
  type: "string",
  enum: ["auto", "window", "menu", "dialog"],
  description: "auto focuses an open menu or dialog; window returns the window tree"
}

export const computerUseTools: ReadonlyArray<Tool> = [
  tool(
    "js",
    "Run JavaScript in a persistent, session-scoped Computer Use REPL. Use computer.getApp(name), app.getState(), app.click(index), app.pressKey(key), app.waitFor(options), and computer.write(value). Record a fix with app.startRecording(), interact across calls, then recording.stop() to get an embeddable video artifact. Top-level bindings survive calls. Actions do not capture state. Only documented computer APIs are available; no filesystem, network, or arbitrary host access.",
    { code: { type: "string" } },
    ["code"]
  ),
  tool(
    "reset",
    "Reset this session's Computer Use JavaScript bindings and app/window references. Does not close apps or erase their contents."
  ),
  tool("list_apps", "List installed desktop applications, including whether each app is running."),
  tool(
    "list_recording_targets",
    "List capturable windows and displays on macOS, with IDs, titles, owning apps and dimensions. Choose one window or one full display for a screen recording."
  ),
  tool(
    "start_recording",
    "Start a silent MP4 screen recording on macOS and return its recordingId once capture begins. Supply exactly one observed window_id or display_id. Recording continues across tool calls so you can demonstrate a fix. Stop to obtain the file and local attachment path. No CLI is needed.",
    {
      window_id: window,
      display_id: {
        type: "integer",
        minimum: 1,
        description:
          "displayId from list_recording_targets; records everything visible on that monitor"
      },
      fps: { type: "integer", minimum: 1, maximum: 60, description: "Default 30" },
      max_dimension: {
        type: "integer",
        minimum: 640,
        maximum: 3840,
        description: "Maximum output width/height, preserving aspect ratio; default 1920"
      },
      max_duration_seconds: {
        type: "integer",
        minimum: 1,
        maximum: 300,
        description: "Auto-stop after this duration; default 60 seconds. Also stops at 100 MB."
      },
      show_cursor: { type: "boolean", description: "Include the hardware cursor; default true" }
    }
  ),
  tool(
    "recording_status",
    "Get one recording or list this session's recordings when recording_id is omitted. Completed recordings include a local file and, in Codevisor, a durable local video attachment and Markdown to embed in chat. Available after a REPL reset or automatic stop.",
    { recording_id: { type: "string" } }
  ),
  tool(
    "stop_recording",
    "Stop and finalize this session's recording. Returns a playable MP4 file with path, MIME type, duration and dimensions, plus a durable local attachment path and Markdown for the chat. Safe to repeat; waits for the file to finish writing. Use after demonstrating the implemented fix.",
    { recording_id: { type: "string" } },
    ["recording_id"]
  ),
  tool(
    "get_app_state",
    "Launch the app if needed, then explicitly observe its accessibility text and optional screenshot. Actions never take hidden snapshots. Observe after a UI change before choosing another element.",
    {
      app,
      window_id: window,
      view,
      screenshot: {
        type: "boolean",
        description: "Include a screenshot (default true); false reads accessibility only"
      },
      include_frames: {
        type: "boolean",
        description: "Include element frames in the text; defaults to the screenshot setting"
      },
      disableDiff: {
        type: "boolean",
        description:
          "true (default) returns full text; false returns changes from this window's previous observation"
      }
    },
    ["app"]
  ),
  tool(
    "wait_for",
    "Observe until text or a role appears/disappears, without sending input. Returns the matching state or a timeout with the last state. Use this for menus, dialogs and search results.",
    {
      app,
      window_id: window,
      view,
      text: {
        type: "string",
        description: "Case-sensitive text contained in the accessibility observation"
      },
      role: { type: "string", description: "Accessibility role, e.g. AXMenu or AXSheet on macOS" },
      state: { type: "string", enum: ["present", "absent"] },
      timeout_ms: { type: "integer", minimum: 0, maximum: 30000 },
      screenshot: {
        type: "boolean",
        description: "Capture once after the condition matches (default false)"
      }
    },
    ["app"]
  ),
  tool(
    "click",
    "Click an observed element or screenshot point. Accessibility is preferred; uncertain delivery must be observed before retrying.",
    {
      ...target,
      x: point,
      y: point,
      mouse_button: { type: "string", enum: ["left", "right", "middle", "l", "r", "m"] },
      click_count: { type: "integer", minimum: 1, maximum: 2 }
    },
    ["app"]
  ),
  tool(
    "drag",
    "Drag between observed elements or screenshot pixels. Each endpoint takes an element index or x/y, exclusively. A moved or resized window requires a fresh screenshot.",
    {
      app,
      window_id: window,
      snapshot_id: snapshot,
      delivery_mode: delivery,
      from_element_index: element,
      to_element_index: element,
      from_x: point,
      from_y: point,
      to_x: point,
      to_y: point
    },
    ["app"]
  ),
  tool(
    "perform_secondary_action",
    "Perform an action advertised by the current element. Clean action labels in the observation are accepted.",
    {
      ...target,
      action: { type: "string" }
    },
    ["app", "element_index", "action"]
  ),
  tool(
    "press_key",
    "Press a key/chord or an ordered sequence of up to 32 keys. Sequences retain focus and do not insert observations between keystrokes.",
    {
      app,
      window_id: window,
      delivery_mode: delivery,
      key: { type: "string" },
      keys: { type: "array", items: { type: "string" }, minItems: 1, maxItems: 32 }
    },
    ["app"]
  ),
  tool(
    "scroll",
    "Scroll the observed element or selected window by pages; prefers advertised accessibility scroll actions.",
    {
      ...target,
      direction: { type: "string", enum: ["up", "down", "left", "right", "u", "d", "l", "r"] },
      pages: { type: "number", exclusiveMinimum: 0, maximum: 20 }
    },
    ["app", "direction"]
  ),
  tool(
    "select_text",
    "Select an exact text match in an editable accessibility element. Add prefix/suffix to disambiguate repeated text.",
    {
      ...target,
      text: { type: "string" },
      prefix: { type: "string" },
      suffix: { type: "string" },
      selection_type: { type: "string", enum: ["text", "cursor_before", "cursor_after"] }
    },
    ["app", "element_index", "text"]
  ),
  tool(
    "set_value",
    "Replace an observed accessibility element's value; this does not submit a search or press Return.",
    {
      ...target,
      value: { type: "string" }
    },
    ["app", "element_index", "value"]
  ),
  tool(
    "type_text",
    "Type plain text into an observed editable element or the focused control, without using the clipboard.",
    {
      ...target,
      text: { type: "string" }
    },
    ["app", "text"]
  ),
  tool(
    "paste_text",
    "Paste plain text with optional HTML formatting on macOS. Requires foreground delivery; restores the clipboard unless another app changed it. Observe the pasted content to verify formatting.",
    {
      ...target,
      text: { type: "string" },
      html: { type: "string" }
    },
    ["app", "text"]
  )
]
