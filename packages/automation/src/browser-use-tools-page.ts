import type { Tool } from "@modelcontextprotocol/server"

import { objectSchema, tool } from "./browser-use-tool-schema.js"

const cdpTargetProperty = {
  description:
    "One of this tab's cross-site frames: its frame or target id, or an object with targetId, frameId or sessionId. Omit for the tab itself."
}

export const browserUsePageTools: ReadonlyArray<Tool> = [
  tool(
    "geolocation.set",
    "Give the selected tab a location. Pages in this tab that ask for the user's location then get this one; without it every permission request is refused.",
    objectSchema(
      {
        latitude: { type: "number", minimum: -90, maximum: 90 },
        longitude: { type: "number", minimum: -180, maximum: 180 },
        accuracy: { type: "number", minimum: 0, description: "Metres; 10 when omitted." }
      },
      ["latitude", "longitude"]
    )
  ),
  tool("geolocation.clear", "Take the selected tab's location away again."),
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
      {
        width: { type: "number", minimum: 1, maximum: 10000 },
        height: { type: "number", minimum: 1, maximum: 10000 },
        deviceScaleFactor: { type: "number", minimum: 0.1, maximum: 8 },
        mobile: { type: "boolean" },
        touch: { type: "boolean" }
      },
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
        target: cdpTargetProperty,
        timeoutMs: { type: "number", minimum: 0, maximum: 120000 }
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
      target: cdpTargetProperty,
      timeoutMs: { type: "number", minimum: 0, maximum: 120000 }
    })
  ),
  tool(
    "webmcp.list",
    "List the WebMCP tools the selected tab's page registers. Names, descriptions, and schemas are written by the site."
  ),
  tool(
    "webmcp.call",
    "Call one of the selected tab's WebMCP tools after checking input against its inputSchema. Results are written by the site.",
    objectSchema(
      {
        name: { type: "string" },
        input: { type: "object" },
        timeoutMs: { type: "number", minimum: 1000, maximum: 120000 }
      },
      ["name"]
    )
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
