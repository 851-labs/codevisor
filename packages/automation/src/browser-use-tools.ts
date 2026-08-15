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

const stringProperty = (description: string) => ({ type: "string", description })
const targetProperties = {
  element: stringProperty("Short human-readable description of the intended element"),
  target: stringProperty("Exact ref (for example e12) from the latest Browser Use snapshot")
}

const locatorProperty = {
  type: "object",
  description:
    "Playwright-style locator created by tools.browser.tab.playwright or supplied as one exact locator descriptor.",
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

const locatorSchema = (
  properties: Readonly<Record<string, unknown>> = {},
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

const tool = (
  name: string,
  description: string,
  inputSchema: Readonly<Record<string, unknown>> = objectSchema()
): Tool => ({ name, description, inputSchema: inputSchema as Tool["inputSchema"] })

export const browserUseTools: ReadonlyArray<Tool> = [
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
    "List, create, close, or select a browser tab. Use action new to open a URL that is not already open; use openTabs and claimTab only to take over a specifically matched existing tab.",
    objectSchema(
      {
        action: { type: "string", enum: ["list", "new", "close", "select"] },
        id: { type: "string" },
        index: { type: "number", minimum: 0 },
        url: { type: "string" }
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
    "Press a key or chord in the page using trusted CDP keyboard input.",
    objectSchema({ key: { type: "string" } }, ["key"])
  ),
  tool(
    "keyboard_type",
    "Type text at the currently focused page element using trusted CDP input.",
    objectSchema({ text: { type: "string" } }, ["text"])
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
    "Move the page pointer to CSS viewport coordinates.",
    objectSchema(
      {
        x: { type: "number" },
        y: { type: "number" },
        keys: { type: "array", items: { type: "string" } }
      },
      ["x", "y"]
    )
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
    "Scroll by CSS pixel deltas.",
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
  ),
  tool(
    "playwright.count",
    "Count elements matching one Playwright-style locator.",
    locatorSchema()
  ),
  tool(
    "playwright.click",
    "Click the unique element matching a Playwright-style locator.",
    locatorSchema({
      button: { type: "string", enum: ["left", "right", "middle"] },
      doubleClick: { type: "boolean" },
      force: { type: "boolean" },
      modifiers: {
        type: "array",
        items: {
          type: "string",
          enum: ["Alt", "Control", "ControlOrMeta", "Meta", "Shift"]
        }
      }
    })
  ),
  tool(
    "playwright.fill",
    "Replace the value of the unique editable control matching a Playwright-style locator.",
    locatorSchema({ value: { type: "string" } }, ["value"])
  ),
  tool(
    "playwright.type",
    "Type without clearing the unique editable control matching a Playwright-style locator.",
    locatorSchema({ value: { type: "string" } }, ["value"])
  ),
  tool(
    "playwright.press",
    "Focus the unique matching element and press a Playwright-compatible key or chord.",
    locatorSchema({ key: { type: "string" } }, ["key"])
  ),
  tool(
    "playwright.check",
    "Check the unique checkbox or radio matching a Playwright-style locator.",
    locatorSchema({ force: { type: "boolean" } })
  ),
  tool(
    "playwright.uncheck",
    "Uncheck the unique checkbox matching a Playwright-style locator.",
    locatorSchema({ force: { type: "boolean" } })
  ),
  tool(
    "playwright.setChecked",
    "Set the checked state of the unique checkbox or radio matching a Playwright-style locator.",
    locatorSchema({ checked: { type: "boolean" }, force: { type: "boolean" } }, ["checked"])
  ),
  tool(
    "playwright.selectOption",
    "Select options by value, label, or index on the unique native select matching a Playwright-style locator.",
    locatorSchema(
      {
        values: {
          type: "array",
          items: {
            oneOf: [
              { type: "string" },
              {
                type: "object",
                properties: {
                  value: { type: "string" },
                  label: { type: "string" },
                  index: { type: "number", minimum: 0 }
                },
                additionalProperties: false
              }
            ]
          }
        }
      },
      ["values"]
    )
  ),
  tool(
    "playwright.isVisible",
    "Return whether the first element matching a Playwright-style locator is visible.",
    locatorSchema()
  ),
  tool(
    "playwright.isEnabled",
    "Return whether the first element matching a Playwright-style locator is enabled.",
    locatorSchema()
  ),
  tool(
    "playwright.getAttribute",
    "Read one attribute from the unique element matching a Playwright-style locator.",
    locatorSchema({ name: { type: "string" } }, ["name"])
  ),
  tool(
    "playwright.innerText",
    "Read rendered text from the unique element matching a Playwright-style locator.",
    locatorSchema()
  ),
  tool(
    "playwright.textContent",
    "Read textContent from the unique element matching a Playwright-style locator.",
    locatorSchema()
  ),
  tool(
    "playwright.waitFor",
    "Wait for a Playwright-style locator to become attached, detached, visible, or hidden.",
    locatorSchema(
      {
        state: { type: "string", enum: ["attached", "detached", "visible", "hidden"] },
        timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
      },
      ["state"]
    )
  ),
  tool(
    "playwright.waitForTimeout",
    "Wait for a bounded number of milliseconds.",
    objectSchema({ timeoutMs: { type: "number", minimum: 0, maximum: 30000 } }, ["timeoutMs"])
  ),
  tool(
    "playwright.waitForURL",
    "Wait for the selected tab URL to equal the requested URL.",
    objectSchema(
      {
        url: { type: "string" },
        timeoutMs: { type: "number", minimum: 0, maximum: 30000 },
        waitUntil: {
          type: "string",
          enum: ["commit", "domcontentloaded", "load", "networkidle"]
        }
      },
      ["url"]
    )
  ),
  tool(
    "playwright.waitForLoadState",
    "Wait for the selected tab to reach a requested document load state.",
    objectSchema({
      state: { type: "string", enum: ["domcontentloaded", "load", "networkidle"] },
      timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
    })
  ),
  tool(
    "playwright.allTextContents",
    "Read textContent from every element matching a Playwright-style locator.",
    locatorSchema()
  ),
  tool(
    "playwright.evaluate",
    "Run a read-only function in the page or against one locator. Mutating JavaScript is rejected.",
    objectSchema(
      {
        locator: locatorProperty,
        function: { type: "string" },
        arg: {},
        timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
      },
      ["function"]
    )
  ),
  tool(
    "playwright.downloadMedia",
    "Trigger a browser download for the media or file link matched by one locator.",
    locatorSchema({ timeoutMs: { type: "number", minimum: 0, maximum: 30000 } })
  ),
  tool(
    "playwright.waitForEvent",
    "Wait for a native-style filechooser or download event.",
    objectSchema(
      {
        event: { type: "string", enum: ["filechooser", "download"] },
        timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
      },
      ["event"]
    )
  ),
  tool(
    "playwright.fileChooserSetFiles",
    "Set workspace files on a file chooser returned by playwright.waitForEvent.",
    objectSchema(
      {
        chooserId: { type: "string" },
        paths: { type: "array", items: { type: "string" } },
        timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
      },
      ["chooserId", "paths"]
    )
  ),
  tool(
    "playwright.downloadPath",
    "Return the local path for a completed download event.",
    objectSchema(
      {
        downloadId: { type: "string" },
        timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
      },
      ["downloadId"]
    )
  ),
  tool("clipboard.readText", "Read plain text from the selected tab's browser clipboard."),
  tool(
    "clipboard.writeText",
    "Write plain text to the selected tab's browser clipboard.",
    objectSchema({ text: { type: "string" } }, ["text"])
  ),
  tool(
    "clipboard.read",
    "Read clipboard items, including base64-encoded binary data, from the selected tab."
  ),
  tool(
    "clipboard.write",
    "Write native-style clipboard items to the selected tab.",
    objectSchema(
      {
        items: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              presentationStyle: {
                type: "string",
                enum: ["unspecified", "inline", "attachment"]
              },
              entries: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    mimeType: { type: "string" },
                    text: { type: "string" },
                    base64: { type: "string" }
                  },
                  required: ["mimeType"]
                }
              }
            },
            required: ["entries"]
          }
        }
      },
      ["items"]
    )
  ),
  tool(
    "dev.logs",
    "Read console messages and uncaught page errors captured for the selected tab.",
    objectSchema({
      filter: { type: "string" },
      levels: {
        type: "array",
        items: { type: "string", enum: ["debug", "info", "log", "warn", "error", "warning"] }
      },
      limit: { type: "number", minimum: 1, maximum: 1000 }
    })
  ),
  tool("getJsDialog", "Return the active JavaScript dialog, if any."),
  tool(
    "user.history",
    "Search Chrome history when the user-browser extension backend is active.",
    objectSchema({
      from: { oneOf: [{ type: "string" }, { type: "number" }] },
      to: { oneOf: [{ type: "string" }, { type: "number" }] },
      queries: { type: "array", items: { type: "string" } },
      limit: { type: "number", minimum: 1, maximum: 1000 }
    })
  ),
  tool(
    "viewport.set",
    "Set a CDP viewport override for the selected tab.",
    objectSchema(
      { width: { type: "number", minimum: 1 }, height: { type: "number", minimum: 1 } },
      ["width", "height"]
    )
  ),
  tool("viewport.reset", "Clear the selected tab's viewport override."),
  tool(
    "cdp.send",
    "Send a raw Chrome DevTools Protocol command to the selected tab.",
    objectSchema(
      {
        method: { type: "string" },
        params: { type: "object" },
        target: { type: "object" },
        timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
      },
      ["method"]
    )
  ),
  tool(
    "cdp.readEvents",
    "Read captured Chrome DevTools Protocol events using a sequence cursor.",
    objectSchema({
      afterSequence: { type: "number", minimum: 0 },
      limit: { type: "number", minimum: 1, maximum: 1000 },
      methods: { type: "array", items: { type: "string" } },
      target: { type: "object" },
      timeoutMs: { type: "number", minimum: 0, maximum: 30000 }
    })
  ),
  tool("pageAssets.list", "Inventory images, stylesheets, scripts, media, and inline SVGs."),
  tool(
    "pageAssets.bundle",
    "Save selected page assets into a local bundle.",
    objectSchema(
      {
        inventoryId: { type: "string" },
        assetIds: { type: "array", items: { type: "string" } },
        kinds: { type: "array", items: { type: "string" } }
      },
      ["inventoryId"]
    )
  )
]
