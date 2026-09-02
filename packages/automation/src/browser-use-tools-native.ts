import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import { objectSchema, targetProperties, tool } from "./browser-use-tool-schema.js"

/// Backend selection, tab lifecycle, navigation, capture, and native element/coordinate interactions.
export const browserUseNativeTools: ReadonlyArray<Tool> = [
  tool("backends", "List Codevisor Browser Use backends and current availability."),
  tool(
    "connection_status",
    "Return the selected backend and its connection phase without waiting for a browser picker."
  ),
  tool(
    "use_backend",
    "Select the Browser Use backend for this session. extension connects to the user's open Chrome through Codevisor's bundled relay; managed uses Codevisor's isolated Chromium fallback. The connection response is always nonblocking.",
    objectSchema({ backend: { type: "string", enum: ["managed", "extension"] } }, ["backend"])
  ),
  tool(
    "tabs",
    "List, create, close, or select a browser tab. Use action new to open a URL that is not already open; use openTabs and claimTab only to take over a specifically matched existing tab. scope session lists only tabs this session created, claimed, or kept at an earlier finalize, with their origin.",
    objectSchema(
      {
        action: { type: "string", enum: ["list", "new", "close", "select"] },
        id: { type: "string" },
        index: { type: "number", minimum: 0 },
        url: { type: "string" },
        scope: { type: "string", enum: ["all", "session"] }
      },
      ["action"]
    )
  ),
  tool(
    "openTabs",
    "Native-style alias that lists open tabs without claiming one. Use claimTab before inspecting or acting on a user-browser tab."
  ),
  tool(
    "claimTab",
    "Native-style alias that claims one tab returned by openTabs for this session.",
    objectSchema({ id: { type: "string" }, index: { type: "number", minimum: 0 } })
  ),
  tool(
    "finalizeTabs",
    "Release this session's claimed tab. Existing user tabs remain open unless close is true.",
    objectSchema({
      close: { type: "boolean" },
      native: { type: "boolean" },
      keepIds: { type: "array", items: { type: "string" } }
    })
  ),
  tool(
    "markTab",
    "Mark a tab as a user-facing deliverable or a handoff that should remain open.",
    objectSchema(
      {
        id: { type: "string" },
        status: { type: "string", enum: ["deliverable", "handoff"] }
      },
      ["status"]
    )
  ),
  tool(
    "tab_groups",
    "Organize tabs into Chrome tab groups in the user's browser. list returns every group with its tab ids; ensure adds tabIds to the group whose title matches (creating it with color if none exists) and is the right choice for a group you keep adding to; create always makes a new group; add moves tabIds into groupId; update changes a group's title, color, or collapsed state; ungroup removes tabIds from their groups. Colors: grey, blue, red, yellow, green, pink, purple, cyan, orange. User Chrome backend only.",
    objectSchema(
      {
        action: { type: "string", enum: ["list", "create", "ensure", "add", "update", "ungroup"] },
        tabIds: { type: "array", items: { type: "string" }, minItems: 1 },
        groupId: { type: "number" },
        title: { type: "string" },
        color: {
          type: "string",
          enum: ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
        },
        collapsed: { type: "boolean" }
      },
      ["action"]
    )
  ),
  tool("tab_info", "Return id, title, and URL for the selected browser tab."),
  tool(
    "navigate",
    "Navigate the selected tab to an HTTP(S) URL.",
    objectSchema({ url: { type: "string" } }, ["url"])
  ),
  tool("back", "Navigate the selected tab back."),
  tool("forward", "Navigate the selected tab forward."),
  tool("reload", "Reload the selected tab."),
  tool(
    "snapshot",
    "Capture a fresh page accessibility tree with snapshot-scoped element refs. Prefer refs over coordinates and re-snapshot after every action.",
    objectSchema({ depth: { type: "number", minimum: 1, maximum: 60 }, boxes: { type: "boolean" } })
  ),
  tool(
    "screenshot",
    "Capture the selected viewport or one ref from the latest snapshot.",
    objectSchema({
      target: { type: "string" },
      type: { type: "string", enum: ["png", "jpeg"] },
      fullPage: { type: "boolean" },
      clip: {
        type: "object",
        properties: {
          x: { type: "number" },
          y: { type: "number" },
          width: { type: "number" },
          height: { type: "number" }
        },
        required: ["x", "y", "width", "height"],
        additionalProperties: false
      }
    })
  ),
  tool(
    "click",
    "Click an exact ref from the latest snapshot. Codevisor checks attachment, visibility, disabled state, and hit targeting before dispatching trusted CDP mouse input.",
    objectSchema(
      {
        ...targetProperties,
        doubleClick: { type: "boolean" },
        button: { type: "string", enum: ["left", "right", "middle"] }
      },
      ["target"]
    )
  ),
  tool(
    "drag",
    "Drag from one current snapshot ref to another using trusted CDP mouse input.",
    objectSchema(
      {
        startElement: { type: "string" },
        startTarget: { type: "string" },
        endElement: { type: "string" },
        endTarget: { type: "string" }
      },
      ["startTarget", "endTarget"]
    )
  ),
  tool(
    "hover",
    "Hover an exact ref from the latest snapshot.",
    objectSchema(targetProperties, ["target"])
  ),
  tool(
    "type",
    "Focus an editable ref and replace its text using trusted CDP text input.",
    objectSchema(
      {
        ...targetProperties,
        text: { type: "string" },
        slowly: { type: "boolean" },
        submit: { type: "boolean" }
      },
      ["target", "text"]
    )
  ),
  tool(
    "fill_form",
    "Fill several controls. Each field must contain target (a current ref) and value.",
    objectSchema({ fields: { type: "array", items: { type: "object" } } }, ["fields"])
  ),
  tool(
    "select_option",
    "Select values in a select ref from the latest snapshot.",
    objectSchema({ ...targetProperties, values: { type: "array", items: { type: "string" } } }, [
      "target",
      "values"
    ])
  ),
  tool(
    "press_key",
    "Press a key or chord in the page using trusted CDP keyboard input. Modifier keys held through key_down apply.",
    objectSchema({ key: { type: "string" } }, ["key"])
  ),
  tool(
    "key_down",
    "Hold a key down using trusted CDP keyboard input, like Playwright's keyboard.down. Held modifier keys (Shift, Control, Alt, Meta) apply to later key events until key_up.",
    objectSchema({ key: { type: "string" } }, ["key"])
  ),
  tool(
    "key_up",
    "Release a key held by key_down, like Playwright's keyboard.up.",
    objectSchema({ key: { type: "string" } }, ["key"])
  ),
  tool(
    "keyboard_type",
    "Type text at the currently focused page element using trusted CDP input. mode keys presses each character as a key event (Playwright's keyboard.type); the default inserts the text directly (keyboard.insertText).",
    objectSchema({ text: { type: "string" }, mode: { type: "string", enum: ["insert", "keys"] } }, [
      "text"
    ])
  ),
  tool(
    "wait",
    "Wait for visible page text, text disappearance, or a duration in seconds.",
    objectSchema({
      text: { type: "string" },
      textGone: { type: "string" },
      time: { type: "number", minimum: 0, maximum: 30 }
    })
  ),
  tool(
    "dialog",
    "Accept or dismiss the active JavaScript dialog.",
    objectSchema({ accept: { type: "boolean" }, promptText: { type: "string" } }, ["accept"])
  ),
  tool(
    "upload_files",
    "Set workspace files on a file-input ref from the latest snapshot.",
    objectSchema(
      { target: { type: "string" }, paths: { type: "array", items: { type: "string" } } },
      ["target", "paths"]
    )
  ),
  tool(
    "mouse_click",
    "Click CSS viewport coordinates only when no semantic ref exists. Coordinates match a Browser Use viewport screenshot.",
    objectSchema(
      {
        x: { type: "number" },
        y: { type: "number" },
        button: { type: "string", enum: ["left", "right", "middle"] },
        doubleClick: { type: "boolean" },
        keypress: { type: "array", items: { type: "string" } }
      },
      ["x", "y"]
    )
  ),
  tool(
    "mouse_move",
    "Move the page pointer to CSS viewport coordinates. While a button is held through mouse_down the move drags; steps interpolates intermediate moves like Playwright's mouse.move.",
    objectSchema(
      {
        x: { type: "number" },
        y: { type: "number" },
        steps: { type: "number", minimum: 1 },
        keys: { type: "array", items: { type: "string" } }
      },
      ["x", "y"]
    )
  ),
  tool(
    "mouse_down",
    "Press and hold a mouse button at the current pointer position (or x, y) using trusted CDP input, like Playwright's mouse.down. Pair with mouse_move and mouse_up to drag.",
    objectSchema({
      x: { type: "number" },
      y: { type: "number" },
      button: { type: "string", enum: ["left", "right", "middle"] },
      clickCount: { type: "number", minimum: 1 },
      keys: { type: "array", items: { type: "string" } }
    })
  ),
  tool(
    "mouse_up",
    "Release a mouse button held by mouse_down at the current pointer position (or x, y), like Playwright's mouse.up.",
    objectSchema({
      x: { type: "number" },
      y: { type: "number" },
      button: { type: "string", enum: ["left", "right", "middle"] },
      clickCount: { type: "number", minimum: 1 },
      keys: { type: "array", items: { type: "string" } }
    })
  ),
  tool(
    "mouse_drag",
    "Drag between CSS viewport coordinates.",
    objectSchema({
      startX: { type: "number" },
      startY: { type: "number" },
      endX: { type: "number" },
      endY: { type: "number" },
      path: {
        type: "array",
        items: {
          type: "object",
          properties: { x: { type: "number" }, y: { type: "number" } },
          required: ["x", "y"],
          additionalProperties: false
        },
        minItems: 2
      },
      keys: { type: "array", items: { type: "string" } }
    })
  ),
  tool(
    "mouse_scroll",
    "Scroll by CSS pixel deltas at x, y, or at the current pointer position when omitted.",
    objectSchema(
      {
        x: { type: "number" },
        y: { type: "number" },
        deltaX: { type: "number" },
        deltaY: { type: "number" },
        keypress: { type: "array", items: { type: "string" } }
      },
      ["deltaY"]
    )
  ),
  tool(
    "mouse_download_media",
    "Trigger a media download at CSS viewport coordinates.",
    objectSchema(
      {
        x: { type: "number" },
        y: { type: "number" },
        timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
      },
      ["x", "y"]
    )
  ),
  tool(
    "dom_download_media",
    "Trigger a media download for a current snapshot ref.",
    objectSchema(
      {
        target: { type: "string" },
        timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
      },
      ["target"]
    )
  ),
  tool(
    "dom_scroll",
    "Scroll the page or a current snapshot ref by CSS pixel deltas.",
    objectSchema(
      {
        target: { type: "string" },
        x: { type: "number" },
        y: { type: "number" }
      },
      ["x", "y"]
    )
  ),
  tool(
    "playwright.domSnapshot",
    "Return the selected tab's Playwright-style DOM accessibility snapshot."
  )
]
