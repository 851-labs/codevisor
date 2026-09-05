import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import { objectSchema, locatorProperty, locatorSchema, tool } from "./browser-use-tool-schema.js"

/// Playwright-style locator operations.
export const browserUsePlaywrightTools: ReadonlyArray<Tool> = [
  tool(
    "content.export",
    "Export the selected page as Markdown (visible text), HTML, or PDF. Returns a local file and a durable attachment when used through Codevisor.",
    objectSchema({ format: { type: "string", enum: ["markdown", "html", "pdf"] } })
  ),
  tool(
    "playwright.evaluateAll",
    "Evaluate a read-only function against all matching elements.",
    locatorSchema({ function: { type: "string" }, arg: {} }, ["function"])
  ),
  tool(
    "playwright.pressSequentially",
    "Focus the matching element and send individual trusted key events without clearing its text.",
    locatorSchema({ value: { type: "string" } }, ["value"])
  ),
  tool("playwright.armNavigation", "Capture the main-frame navigation baseline before an action."),
  tool(
    "playwright.waitForNavigation",
    "Wait for a navigation after the captured baseline, including same-document navigation.",
    objectSchema(
      {
        afterSequence: { type: "number" },
        frameId: { type: "string" },
        url: { type: "string" },
        timeoutMs: { type: "number" },
        waitUntil: { type: "string", enum: ["commit", "domcontentloaded", "load", "networkidle"] }
      },
      ["afterSequence", "frameId"]
    )
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
  tool("clipboard.readText", "Read plain text from the selected tab's browser clipboard.")
]
