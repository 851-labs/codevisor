import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"
import { parseExpression } from "@babel/parser"
import { createHash, randomUUID } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { basename, dirname, join } from "node:path"
import { spawn, spawnSync, type ChildProcess } from "node:child_process"
import type { AutomationProviderContext, AutomationToolProvider } from "./automation-provider.js"
import { textToolResult } from "./automation-provider.js"
import { CdpConnection, delay, evaluatedValue } from "./browser-cdp.js"
import {
  browserExtensionArchivePath,
  browserExtensionInstallation,
  chromeBrowserAvailable,
  CODEVISOR_BROWSER_EXTENSION_ID,
  makeBrowserExtensionRelay,
  openBrowserExtensionDevelopmentFolder,
  openBrowserExtensionDevelopmentInstaller,
  openBrowserExtensionDevelopmentPage,
  openBrowserExtensionWebStore,
  prepareBrowserExtension
} from "./browser-extension-relay.js"
import type WebSocket from "ws"

export type BrowserBackend = "managed" | "extension"
export type BrowserExtensionSetupMode = "development" | "webStore"

export interface BrowserUseProviderStatus extends Readonly<Record<string, unknown>> {
  readonly extensionConnected: boolean
  readonly chromeAvailable: boolean
  readonly extensionSetupMode: BrowserExtensionSetupMode
  readonly developmentExtensionPath?: string
  readonly extensionArchivePath?: string
}

export interface BrowserUseProvider extends AutomationToolProvider {
  readonly ensureSetup: () => Promise<void>
  readonly status: () => BrowserUseProviderStatus
  readonly sessionBackend: (sessionId: string) => BrowserBackend | undefined
  readonly setSessionBackend: (sessionId: string, backend: BrowserBackend) => void
  readonly acceptExtensionConnection: (socket: WebSocket) => void
  readonly waitForExtensionConnection: () => Promise<void>
  readonly onExtensionConnectionChange: (listener: (connected: boolean) => void) => () => void
  readonly openDevelopmentExtensionFolder: () => void
  readonly openDevelopmentExtensionPage: () => void
  readonly openDevelopmentExtensionInstaller: () => void
  readonly openExtensionWebStore: () => void
  readonly extensionArchivePath: () => string
  readonly extensionIconPath: () => string
  readonly configureExtensionRelay: (serverBaseUrl: string) => void
}

interface TargetInfo {
  readonly targetId: string
  readonly type: string
  readonly title: string
  readonly url: string
}

interface BrowserSnapshot {
  readonly id: string
  readonly targets: ReadonlyMap<string, number>
}

interface BrowserRuntime {
  readonly connection: CdpConnection
  readonly processHandle: ChildProcess | undefined
  readonly owned: boolean
  readonly sessions: Map<string, string>
  readonly snapshots: Map<string, BrowserSnapshot>
  readonly eventLog: Array<{
    readonly method: string
    readonly params: Readonly<Record<string, unknown>>
    readonly sequence: number
    readonly sessionId?: string
  }>
  readonly logs: Map<string, Array<Readonly<Record<string, unknown>>>>
  readonly dialogs: Map<string, Readonly<Record<string, unknown>>>
  readonly fileChoosers: Map<string, { readonly sessionId: string; readonly backendNodeId: number }>
  readonly downloads: Map<
    string,
    {
      readonly guid: string
      readonly url: string
      readonly suggestedFilename: string
      readonly path?: string
      readonly state?: string
    }
  >
  readonly eventDisposers: Array<() => void>
  eventSequence: number
  tabOrder: string[]
  queue: Promise<void>
}

interface ResolvedElement {
  readonly backendNodeId: number
  readonly objectId: string
  readonly x: number
  readonly y: number
  readonly width: number
  readonly height: number
}

interface PageHandle {
  readonly target: TargetInfo
  readonly sessionId: string
}

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

const systemChromePath = (): string | undefined => {
  const taskHome = process.env.HOME
  const candidates =
    process.platform === "darwin"
      ? [
          "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
          ...(taskHome === undefined
            ? []
            : [join(taskHome, "Applications/Google Chrome.app/Contents/MacOS/Google Chrome")])
        ]
      : process.platform === "linux"
        ? [
            "/usr/bin/google-chrome-stable",
            "/usr/bin/google-chrome",
            "/usr/bin/chromium-browser",
            "/usr/bin/chromium",
            "/snap/bin/chromium"
          ]
        : []
  return candidates.find(existsSync)
}

const downloadedChromiumPath = (browsersDir: string): string | undefined => {
  if (!existsSync(browsersDir)) return undefined
  const roots = readdirSync(browsersDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith("chromium-"))
    .map((entry) => join(browsersDir, entry.name))
    .sort()
    .reverse()
  for (const root of roots) {
    const candidates =
      process.platform === "darwin"
        ? [
            join(
              root,
              "chrome-mac-arm64",
              "Google Chrome for Testing.app",
              "Contents",
              "MacOS",
              "Google Chrome for Testing"
            ),
            join(
              root,
              "chrome-mac-x64",
              "Google Chrome for Testing.app",
              "Contents",
              "MacOS",
              "Google Chrome for Testing"
            ),
            join(root, "chrome-mac", "Chromium.app", "Contents", "MacOS", "Chromium")
          ]
        : process.platform === "linux"
          ? [join(root, "chrome-linux64", "chrome"), join(root, "chrome-linux", "chrome")]
          : []
    const executable = candidates.find(existsSync)
    if (executable !== undefined) return executable
  }
  return undefined
}

const runBrowserInstaller = async (browsersDir: string): Promise<void> => {
  const require = createRequire(import.meta.url)
  const packageJson = require.resolve("playwright/package.json")
  const cli = join(dirname(packageJson), "cli.js")
  await new Promise<void>((resolve, reject) => {
    const child = spawn(process.execPath, [cli, "install", "chromium", "--no-shell"], {
      env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: browsersDir },
      stdio: ["ignore", "inherit", "inherit"]
    })
    child.once("error", reject)
    child.once("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`Chromium installer exited with ${code}`))
    )
  })
}

const devToolsEndpoint = (profileDir: string): string | undefined => {
  const file = join(profileDir, "DevToolsActivePort")
  if (!existsSync(file)) return undefined
  const [port, path] = readFileSync(file, "utf8").trim().split(/\r?\n/)
  return port !== undefined && path !== undefined ? `ws://127.0.0.1:${port}${path}` : undefined
}

const connectExistingProfile = async (profileDir: string): Promise<CdpConnection | undefined> => {
  const endpoint = devToolsEndpoint(profileDir)
  if (endpoint === undefined) return undefined
  return CdpConnection.connect(endpoint).catch(() => undefined)
}

export interface ManagedBrowserLaunchEnvironment {
  readonly platform: NodeJS.Platform
  readonly uid: number | undefined
  readonly containerized: boolean
}

export const managedBrowserSandboxArguments = (
  environment: ManagedBrowserLaunchEnvironment
): ReadonlyArray<string> =>
  environment.platform === "linux" && (environment.uid === 0 || environment.containerized)
    ? ["--no-sandbox"]
    : []

const linuxContainerRuntime = (): boolean => {
  if (process.platform !== "linux") return false
  if (process.env.CODEVISOR_BROWSER_NO_SANDBOX === "1") return true
  if (existsSync("/.dockerenv") || existsSync("/run/.containerenv")) return true
  const indicators: ReadonlyArray<readonly [string, RegExp]> = [
    ["/proc/1/cgroup", /(?:docker|containerd|kubepods|podman|lxc)/i],
    ["/proc/cmdline", /(?:^|\s)init=\/sbin\/vminitd(?:\s|$)/]
  ]
  return indicators.some(([path, pattern]) => {
    try {
      return pattern.test(readFileSync(path, "utf8"))
    } catch {
      return false
    }
  })
}

const launchManagedBrowser = async (
  executablePath: string,
  profileDir: string
): Promise<{ connection: CdpConnection; processHandle?: ChildProcess }> => {
  const existing = await connectExistingProfile(profileDir)
  if (existing !== undefined) return { connection: existing }
  rmSync(join(profileDir, "DevToolsActivePort"), { force: true })
  const processHandle = spawn(
    executablePath,
    [
      `--user-data-dir=${profileDir}`,
      "--remote-debugging-port=0",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      ...managedBrowserSandboxArguments({
        platform: process.platform,
        uid: process.getuid?.(),
        containerized: linuxContainerRuntime()
      }),
      ...(process.env.CODEVISOR_BROWSER_HEADLESS === "1" ? ["--headless=new"] : []),
      "about:blank"
    ],
    { stdio: "ignore" }
  )
  let launchError: Error | undefined
  processHandle.once("error", (cause) => {
    launchError = cause
  })
  const deadline = Date.now() + 30_000
  while (Date.now() < deadline) {
    if (launchError !== undefined) throw launchError
    if (processHandle.exitCode !== null) {
      throw new Error(`Chromium exited during startup with ${processHandle.exitCode}`)
    }
    const endpoint = devToolsEndpoint(profileDir)
    if (endpoint !== undefined) {
      try {
        return { connection: await CdpConnection.connect(endpoint), processHandle }
      } catch {
        // DevToolsActivePort can appear one event-loop turn before the socket accepts.
      }
    }
    await delay(100)
  }
  processHandle.kill("SIGTERM")
  throw new Error("Timed out waiting for Chromium's debugging endpoint")
}

const jsonResult = (value: unknown, isError = false): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
  ...(isError ? { isError: true } : {})
})

const pageResult = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  value: Readonly<Record<string, unknown>>
): Promise<CallToolResult> => {
  const dialog = runtime.dialogs.get(page.sessionId)
  // A modal JavaScript dialog pauses Runtime.evaluate in the page. Keep action results
  // nonblocking so the caller can immediately inspect and accept or dismiss the dialog.
  const info =
    dialog === undefined
      ? await pageInformation(runtime, page)
      : { url: page.target.url, title: page.target.title }
  return {
    content: [
      {
        type: "text",
        text: `Page URL: ${info.url}\n${JSON.stringify(
          {
            ...value,
            page: info,
            ...(dialog === undefined ? {} : { dialogOpened: true })
          },
          null,
          2
        )}`
      }
    ]
  }
}

const pageTargets = async (runtime: BrowserRuntime): Promise<TargetInfo[]> => {
  const response = await runtime.connection.send<{ targetInfos: TargetInfo[] }>("Target.getTargets")
  const targets = response.targetInfos.filter((target) => target.type === "page")
  const live = new Set(targets.map((target) => target.targetId))
  runtime.tabOrder = runtime.tabOrder.filter((id) => live.has(id))
  for (const target of targets) {
    if (!runtime.tabOrder.includes(target.targetId)) runtime.tabOrder.push(target.targetId)
  }
  const byId = new Map(targets.map((target) => [target.targetId, target]))
  return runtime.tabOrder.flatMap((id) => {
    const target = byId.get(id)
    return target === undefined ? [] : [target]
  })
}

const waitForCreatedTarget = async (
  runtime: BrowserRuntime,
  targetId: string,
  requestedUrl: string
): Promise<TargetInfo[]> => {
  const deadline = Date.now() + 2_000
  let targets: TargetInfo[] = []
  do {
    targets = await pageTargets(runtime)
    if (targets.some((target) => target.targetId === targetId)) return targets
    await delay(25)
  } while (Date.now() < deadline)

  // Target.createTarget has already succeeded, so reporting failure here would encourage a
  // caller to create the same tab again. Preserve the known target in the response while Chrome
  // finishes publishing its URL through Target.getTargets.
  const created: TargetInfo = {
    targetId,
    type: "page",
    title: "",
    url: requestedUrl
  }
  if (!runtime.tabOrder.includes(targetId)) runtime.tabOrder.push(targetId)
  const byId = new Map(targets.map((target) => [target.targetId, target]))
  byId.set(targetId, created)
  return runtime.tabOrder.flatMap((id) => {
    const target = byId.get(id)
    return target === undefined ? [] : [target]
  })
}

const attachTarget = async (runtime: BrowserRuntime, targetId: string): Promise<string> => {
  const existing = runtime.sessions.get(targetId)
  if (existing !== undefined) return existing
  const attached = await runtime.connection.send<{ sessionId: string }>("Target.attachToTarget", {
    targetId,
    flatten: true
  })
  runtime.sessions.set(targetId, attached.sessionId)
  await Promise.all([
    runtime.connection.send("Page.enable", {}, attached.sessionId),
    runtime.connection.send("Runtime.enable", {}, attached.sessionId),
    runtime.connection.send("DOM.enable", {}, attached.sessionId),
    runtime.connection.send("Accessibility.enable", {}, attached.sessionId),
    runtime.connection.send("Log.enable", {}, attached.sessionId).catch(() => undefined)
  ])
  return attached.sessionId
}

const currentPage = async (
  runtime: BrowserRuntime,
  selectedTargets: Map<string, string>,
  sessionKey: string
): Promise<PageHandle> => {
  let targets = await pageTargets(runtime)
  if (targets.length === 0) {
    const created = await runtime.connection.send<{ targetId: string }>("Target.createTarget", {
      url: "about:blank"
    })
    selectedTargets.set(sessionKey, created.targetId)
    targets = await pageTargets(runtime)
  }
  const selected = selectedTargets.get(sessionKey)
  const target = targets.find((candidate) => candidate.targetId === selected) ?? targets[0]
  if (target === undefined) throw new Error("The browser has no page target")
  selectedTargets.set(sessionKey, target.targetId)
  return { target, sessionId: await attachTarget(runtime, target.targetId) }
}

const evaluate = async <T>(
  runtime: BrowserRuntime,
  page: PageHandle,
  expression: string
): Promise<T> =>
  evaluatedValue<T>(
    await runtime.connection.send(
      "Runtime.evaluate",
      { expression, returnByValue: true, awaitPromise: true },
      page.sessionId
    )
  )

const assertReadOnlyFunction = (source: string): void => {
  let expression: unknown
  try {
    expression = parseExpression(source, {
      plugins: ["typescript"],
      allowAwaitOutsideFunction: true
    })
  } catch (cause) {
    throw new Error(
      `evaluate expects a JavaScript function: ${cause instanceof Error ? cause.message : String(cause)}`
    )
  }
  const mutatingMethods = new Set([
    "append",
    "appendChild",
    "before",
    "blur",
    "click",
    "close",
    "dispatchEvent",
    "focus",
    "insertAdjacentElement",
    "insertAdjacentHTML",
    "insertAdjacentText",
    "insertBefore",
    "open",
    "postMessage",
    "prepend",
    "remove",
    "removeAttribute",
    "removeChild",
    "replaceChildren",
    "replaceWith",
    "requestSubmit",
    "setAttribute",
    "submit",
    "write",
    "writeln"
  ])
  const seen = new WeakSet<object>()
  const visit = (node: unknown): void => {
    if (node === null || typeof node !== "object" || seen.has(node)) return
    seen.add(node)
    const candidate = node as Readonly<Record<string, unknown>>
    const type = candidate.type
    if (
      type === "AssignmentExpression" ||
      type === "UpdateExpression" ||
      type === "NewExpression"
    ) {
      throw new Error("evaluate is read-only and rejects assignment, update, and construction")
    }
    if (type === "UnaryExpression" && candidate.operator === "delete") {
      throw new Error("evaluate is read-only and rejects delete")
    }
    if (type === "CallExpression") {
      const callee = candidate.callee as Readonly<Record<string, unknown>> | undefined
      const property =
        callee?.type === "MemberExpression"
          ? (callee.property as Readonly<Record<string, unknown>> | undefined)
          : undefined
      const name =
        property?.type === "Identifier"
          ? property.name
          : property?.type === "StringLiteral"
            ? property.value
            : undefined
      if (typeof name === "string" && mutatingMethods.has(name)) {
        throw new Error(`evaluate is read-only and rejects ${name}()`)
      }
    }
    for (const [key, value] of Object.entries(candidate)) {
      if (key === "loc" || key === "start" || key === "end") continue
      if (Array.isArray(value)) {
        for (const item of value) visit(item)
      } else visit(value)
    }
  }
  visit(expression)
  const root = expression as { readonly type?: string }
  if (root.type !== "FunctionExpression" && root.type !== "ArrowFunctionExpression") {
    throw new Error("evaluate expects a function")
  }
}

const evaluateReadOnly = async <T>(
  runtime: BrowserRuntime,
  page: PageHandle,
  source: string,
  arg: unknown
): Promise<T> => {
  assertReadOnlyFunction(source)
  const response = await runtime.connection.send<{
    result: { value?: unknown; description?: string }
    exceptionDetails?: { text?: string; exception?: { description?: string } }
  }>(
    "Runtime.evaluate",
    {
      expression: `Promise.resolve((${source})(${JSON.stringify(arg)}))`,
      returnByValue: true,
      awaitPromise: true
    },
    page.sessionId
  )
  if (response.exceptionDetails !== undefined) {
    throw new Error(
      response.exceptionDetails.exception?.description ??
        response.exceptionDetails.text ??
        "Page evaluation failed"
    )
  }
  return response.result.value as T
}

const evaluateLocatorReadOnly = async <T>(
  runtime: BrowserRuntime,
  page: PageHandle,
  locator: unknown,
  source: string,
  arg: unknown
): Promise<T> => {
  assertReadOnlyFunction(source)
  const ids = await locatorBackendNodeIds(runtime, page, locator)
  if (ids.length !== 1) {
    throw new Error(
      ids.length === 0
        ? "Playwright locator resolved to 0 elements"
        : `Playwright strict mode violation: locator resolved to ${ids.length} elements`
    )
  }
  const resolved = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId: ids[0] },
    page.sessionId
  )
  const objectId = resolved.object.objectId
  if (objectId === undefined) throw new Error("Playwright locator is no longer attached")
  try {
    const response = await runtime.connection.send<{
      result: { value?: unknown; description?: string }
      exceptionDetails?: { text?: string; exception?: { description?: string } }
    }>(
      "Runtime.callFunctionOn",
      {
        objectId,
        functionDeclaration: `function(arg){return Promise.resolve((${source})(this,arg));}`,
        arguments: [{ value: arg }],
        returnByValue: true,
        awaitPromise: true
      },
      page.sessionId
    )
    if (response.exceptionDetails !== undefined) {
      throw new Error(
        response.exceptionDetails.exception?.description ??
          response.exceptionDetails.text ??
          "Locator evaluation failed"
      )
    }
    return response.result.value as T
  } finally {
    await runtime.connection
      .send("Runtime.releaseObject", { objectId }, page.sessionId)
      .catch(() => undefined)
  }
}

const waitForCdpEvent = (
  runtime: BrowserRuntime,
  method: string,
  sessionId: string | undefined,
  timeoutMs: number
): Promise<Readonly<Record<string, unknown>>> =>
  new Promise((resolve, reject) => {
    let finished = false
    const stop = runtime.connection.on(
      method,
      (params) => {
        if (finished) return
        finished = true
        clearTimeout(timer)
        stop()
        resolve(params)
      },
      sessionId
    )
    const timer = setTimeout(() => {
      if (finished) return
      finished = true
      stop()
      reject(new Error(`Timed out waiting for ${method}`))
    }, timeoutMs)
    timer.unref?.()
  })

const pageInformation = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<{ url: string; title: string }> =>
  evaluate(runtime, page, "({ url: location.href, title: document.title })")

const waitForReady = async (runtime: BrowserRuntime, page: PageHandle): Promise<void> => {
  const deadline = Date.now() + 15_000
  while (Date.now() < deadline) {
    const state = await evaluate<string>(runtime, page, "document.readyState").catch(
      () => "loading"
    )
    if (state === "interactive" || state === "complete") return
    await delay(100)
  }
  throw new Error("Timed out waiting for the page to become interactive")
}

const grantClipboardPermissions = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<void> => {
  const info = await pageInformation(runtime, page)
  let origin: string
  try {
    origin = new URL(info.url).origin
  } catch {
    return
  }
  const params = {
    origin,
    permissions: ["clipboardReadWrite", "clipboardSanitizedWrite"]
  }
  await runtime.connection
    .send("Browser.grantPermissions", params)
    .catch(() =>
      runtime.connection
        .send("Browser.grantPermissions", params, page.sessionId)
        .catch(() => undefined)
    )
}

interface AXValue {
  readonly value?: unknown
}

interface AXProperty {
  readonly name: string
  readonly value?: AXValue
}

interface AXNode {
  readonly nodeId: string
  readonly parentId?: string
  readonly childIds?: string[]
  readonly ignored: boolean
  readonly role?: AXValue
  readonly name?: AXValue
  readonly value?: AXValue
  readonly properties?: AXProperty[]
  readonly backendDOMNodeId?: number
}

const quoted = (value: unknown): string => {
  const text = String(value ?? "")
    .replaceAll("\n", " ")
    .trim()
  return text.length === 0 ? "" : ` ${JSON.stringify(text.slice(0, 300))}`
}

const snapshotPage = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  depthLimit: number
): Promise<CallToolResult> => {
  const response = await runtime.connection.send<{ nodes: AXNode[] }>(
    "Accessibility.getFullAXTree",
    {},
    page.sessionId
  )
  const nodes = new Map(response.nodes.map((node) => [node.nodeId, node]))
  const roots = response.nodes.filter((node) => node.parentId === undefined)
  const targets = new Map<string, number>()
  const lines: string[] = []
  let nextRef = 1
  const visit = (node: AXNode, depth: number): void => {
    if (depth > depthLimit || lines.length >= 2_000) return
    const role = String(node.role?.value ?? "node")
    const name = node.name?.value
    if (!node.ignored) {
      const ref =
        node.backendDOMNodeId !== undefined &&
        role !== "RootWebArea" &&
        role !== "InlineTextBox" &&
        (role !== "generic" || String(name ?? "").trim().length > 0)
          ? `e${nextRef++}`
          : undefined
      if (ref !== undefined) targets.set(ref, node.backendDOMNodeId!)
      const properties = new Map(
        (node.properties ?? []).map((property) => [property.name, property.value?.value])
      )
      const flags = [
        properties.get("disabled") === true ? "disabled" : undefined,
        properties.get("focused") === true ? "focused" : undefined,
        properties.get("required") === true ? "required" : undefined,
        properties.get("readonly") === true ? "readonly" : undefined
      ].filter((value): value is string => value !== undefined)
      const value = node.value?.value
      lines.push(
        `${"  ".repeat(depth)}- ${role}${quoted(name)}` +
          `${ref === undefined ? "" : ` [ref=${ref}]`}` +
          `${value === undefined || value === "" ? "" : ` [value=${JSON.stringify(String(value).slice(0, 300))}]`}` +
          `${flags.length === 0 ? "" : ` [${flags.join(", ")}]`}`
      )
    }
    for (const childId of node.childIds ?? []) {
      const child = nodes.get(childId)
      if (child !== undefined) visit(child, node.ignored ? depth : depth + 1)
    }
  }
  for (const root of roots) visit(root, 0)
  const snapshotId = randomUUID()
  runtime.snapshots.set(page.target.targetId, { id: snapshotId, targets })
  const info = await pageInformation(runtime, page)
  return {
    content: [
      {
        type: "text",
        text: `Page URL: ${info.url}\nSnapshot: ${snapshotId}\nTitle: ${info.title}\n${lines.join("\n")}`
      }
    ]
  }
}

const normalizeRef = (target: unknown): string => {
  if (typeof target !== "string") throw new Error("target must be a ref from the latest snapshot")
  const match = target.match(/\be\d+\b/)
  if (match === null) throw new Error("target must look like e12 and come from the latest snapshot")
  return match[0]
}

interface BrowserLocator {
  readonly ref?: string
  readonly css?: string
  readonly role?: string
  readonly name?: BrowserTextMatcher
  readonly label?: BrowserTextMatcher
  readonly placeholder?: BrowserTextMatcher
  readonly text?: BrowserTextMatcher
  readonly testId?: string
  readonly exact?: boolean
  readonly scope?: BrowserLocator
  readonly frame?: ReadonlyArray<string>
  readonly filters?: {
    readonly has?: BrowserLocator
    readonly hasNot?: BrowserLocator
    readonly hasText?: BrowserTextMatcher
    readonly hasNotText?: BrowserTextMatcher
    readonly visible?: boolean
  }
  readonly index?: number | "last"
  readonly and?: BrowserLocator
  readonly or?: BrowserLocator
}

type BrowserTextMatcher = string | { readonly regex: string; readonly flags?: string }

const parseTextMatcher = (value: unknown, label: string): BrowserTextMatcher => {
  if (typeof value === "string") return value
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be a string or regular expression`)
  }
  const input = value as Readonly<Record<string, unknown>>
  if (
    typeof input.regex !== "string" ||
    (input.flags !== undefined && typeof input.flags !== "string")
  ) {
    throw new Error(`${label} must contain regex and optional flags strings`)
  }
  try {
    new RegExp(input.regex, input.flags)
  } catch (cause) {
    throw new Error(
      `${label} is invalid: ${cause instanceof Error ? cause.message : String(cause)}`
    )
  }
  return {
    regex: input.regex,
    ...(typeof input.flags === "string" ? { flags: input.flags } : {})
  }
}

const parseLocator = (value: unknown, depth = 0): BrowserLocator => {
  if (depth > 12) throw new Error("locator composition is too deeply nested")
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("locator must be a Playwright-style locator object")
  }
  const locator = value as Readonly<Record<string, unknown>>
  const modes = ["ref", "css", "role", "label", "placeholder", "text", "testId"].filter((key) => {
    const candidate = locator[key]
    return typeof candidate === "string"
      ? candidate.length > 0
      : ["label", "placeholder", "text"].includes(key) &&
          candidate !== null &&
          typeof candidate === "object"
  })
  if (modes.length !== 1) {
    throw new Error(
      "locator must contain exactly one of ref, css, role, label, placeholder, text, or testId"
    )
  }
  if (locator.role === undefined && locator.name !== undefined) {
    throw new Error("locator.name is only valid with locator.role")
  }
  if (
    locator.frame !== undefined &&
    (!Array.isArray(locator.frame) ||
      !locator.frame.every((selector) => typeof selector === "string" && selector.length > 0))
  ) {
    throw new Error("locator.frame must be an array of frame selectors")
  }
  if (
    locator.index !== undefined &&
    locator.index !== "last" &&
    (typeof locator.index !== "number" || !Number.isInteger(locator.index) || locator.index < 0)
  ) {
    throw new Error("locator.index must be a non-negative integer or last")
  }
  const scope = locator.scope === undefined ? undefined : parseLocator(locator.scope, depth + 1)
  const and = locator.and === undefined ? undefined : parseLocator(locator.and, depth + 1)
  const or = locator.or === undefined ? undefined : parseLocator(locator.or, depth + 1)
  let filters: BrowserLocator["filters"]
  if (locator.filters !== undefined) {
    if (
      locator.filters === null ||
      typeof locator.filters !== "object" ||
      Array.isArray(locator.filters)
    ) {
      throw new Error("locator.filters must be an object")
    }
    const input = locator.filters as Readonly<Record<string, unknown>>
    if (input.visible !== undefined && typeof input.visible !== "boolean") {
      throw new Error("locator.filters.visible must be a boolean")
    }
    filters = {
      ...(input.has === undefined ? {} : { has: parseLocator(input.has, depth + 1) }),
      ...(input.hasNot === undefined ? {} : { hasNot: parseLocator(input.hasNot, depth + 1) }),
      ...(input.hasText === undefined
        ? {}
        : { hasText: parseTextMatcher(input.hasText, "locator.filters.hasText") }),
      ...(input.hasNotText === undefined
        ? {}
        : { hasNotText: parseTextMatcher(input.hasNotText, "locator.filters.hasNotText") }),
      ...(typeof input.visible === "boolean" ? { visible: input.visible } : {})
    }
  }
  return {
    ...(locator.ref === undefined ? {} : { ref: String(locator.ref) }),
    ...(locator.css === undefined ? {} : { css: String(locator.css) }),
    ...(locator.role === undefined ? {} : { role: String(locator.role) }),
    ...(locator.name === undefined ? {} : { name: parseTextMatcher(locator.name, "locator.name") }),
    ...(locator.label === undefined
      ? {}
      : { label: parseTextMatcher(locator.label, "locator.label") }),
    ...(locator.placeholder === undefined
      ? {}
      : { placeholder: parseTextMatcher(locator.placeholder, "locator.placeholder") }),
    ...(locator.text === undefined ? {} : { text: parseTextMatcher(locator.text, "locator.text") }),
    ...(locator.testId === undefined ? {} : { testId: String(locator.testId) }),
    ...(locator.exact === true ? { exact: true } : {}),
    ...(scope === undefined ? {} : { scope }),
    ...(locator.frame === undefined ? {} : { frame: locator.frame as string[] }),
    ...(filters === undefined ? {} : { filters }),
    ...(locator.index === undefined ? {} : { index: locator.index as number | "last" }),
    ...(and === undefined ? {} : { and }),
    ...(or === undefined ? {} : { or })
  }
}

const backendNodeIdsFromArrayObject = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  arrayObjectId: string
): Promise<number[]> => {
  const elementObjectIds: string[] = []
  try {
    const properties = await runtime.connection.send<{
      result: Array<{ name: string; value?: { objectId?: string } }>
    }>("Runtime.getProperties", { objectId: arrayObjectId, ownProperties: true }, page.sessionId)
    const ids: number[] = []
    for (const property of properties.result) {
      if (!/^\d+$/.test(property.name)) continue
      const objectId = property.value?.objectId
      if (objectId === undefined) continue
      elementObjectIds.push(objectId)
      const described = await runtime.connection.send<{ node: { backendNodeId: number } }>(
        "DOM.describeNode",
        { objectId },
        page.sessionId
      )
      ids.push(described.node.backendNodeId)
    }
    return [...new Set(ids)]
  } finally {
    await Promise.all(
      [arrayObjectId, ...elementObjectIds].map((objectId) =>
        runtime.connection
          .send("Runtime.releaseObject", { objectId }, page.sessionId)
          .catch(() => undefined)
      )
    )
  }
}

const backendNodeIdsFromRootFunction = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  rootBackendNodeId: number,
  functionDeclaration: string,
  args: ReadonlyArray<unknown> = []
): Promise<number[]> => {
  const root = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId: rootBackendNodeId },
    page.sessionId
  )
  const rootObjectId = root.object.objectId
  if (rootObjectId === undefined) throw new Error("Locator root is no longer attached")
  try {
    const evaluated = await runtime.connection.send<{
      result: { objectId?: string; description?: string }
      exceptionDetails?: { text?: string; exception?: { description?: string } }
    }>(
      "Runtime.callFunctionOn",
      {
        objectId: rootObjectId,
        functionDeclaration,
        arguments: args.map((value) => ({ value })),
        returnByValue: false,
        awaitPromise: true
      },
      page.sessionId
    )
    const arrayObjectId = evaluated.result.objectId
    if (arrayObjectId === undefined) {
      const detail =
        evaluated.exceptionDetails?.exception?.description ??
        evaluated.exceptionDetails?.text ??
        evaluated.result.description ??
        "unknown"
      throw new Error(`Locator evaluation did not return elements: ${detail}`)
    }
    return backendNodeIdsFromArrayObject(runtime, page, arrayObjectId)
  } finally {
    await runtime.connection
      .send("Runtime.releaseObject", { objectId: rootObjectId }, page.sessionId)
      .catch(() => undefined)
  }
}

const mainDocumentBackendNodeId = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<number> => {
  const document = await runtime.connection.send<{ root: { backendNodeId: number } }>(
    "DOM.getDocument",
    { depth: 0, pierce: true },
    page.sessionId
  )
  return document.root.backendNodeId
}

const queryCssWithinRoots = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  roots: ReadonlyArray<number>,
  selector: string
): Promise<number[]> => {
  const ids = await Promise.all(
    roots.map((root) =>
      backendNodeIdsFromRootFunction(
        runtime,
        page,
        root,
        "function(selector){return [...this.querySelectorAll(selector)];}",
        [selector]
      )
    )
  )
  return [...new Set(ids.flat())]
}

const filterBackendNodeIdsByRoots = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  ids: ReadonlyArray<number>,
  roots: ReadonlyArray<number>
): Promise<number[]> => {
  if (ids.length === 0 || roots.length === 0) return []
  const rootObjects = await Promise.all(
    roots.map((backendNodeId) =>
      runtime.connection.send<{ object: { objectId?: string } }>(
        "DOM.resolveNode",
        { backendNodeId },
        page.sessionId
      )
    )
  )
  const rootObjectIds = rootObjects.flatMap((root) =>
    root.object.objectId === undefined ? [] : [root.object.objectId]
  )
  try {
    const matches: number[] = []
    for (const backendNodeId of ids) {
      const candidate = await runtime.connection.send<{ object: { objectId?: string } }>(
        "DOM.resolveNode",
        { backendNodeId },
        page.sessionId
      )
      const candidateObjectId = candidate.object.objectId
      if (candidateObjectId === undefined) continue
      try {
        for (const rootObjectId of rootObjectIds) {
          const contained = evaluatedValue<boolean>(
            await runtime.connection.send(
              "Runtime.callFunctionOn",
              {
                objectId: rootObjectId,
                functionDeclaration:
                  "function(candidate){return candidate!==this&&(this.nodeType===9?this.documentElement?.contains(candidate)===true:this.contains(candidate));}",
                arguments: [{ objectId: candidateObjectId }],
                returnByValue: true
              },
              page.sessionId
            )
          )
          if (contained) {
            matches.push(backendNodeId)
            break
          }
        }
      } finally {
        await runtime.connection
          .send("Runtime.releaseObject", { objectId: candidateObjectId }, page.sessionId)
          .catch(() => undefined)
      }
    }
    return matches
  } finally {
    await Promise.all(
      rootObjectIds.map((objectId) =>
        runtime.connection
          .send("Runtime.releaseObject", { objectId }, page.sessionId)
          .catch(() => undefined)
      )
    )
  }
}

const resolveFrameRoots = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  roots: ReadonlyArray<number>,
  selectors: ReadonlyArray<string>
): Promise<number[]> => {
  let current = [...roots]
  for (const selector of selectors) {
    const frames = await queryCssWithinRoots(runtime, page, current, selector)
    if (frames.length === 0)
      throw new Error(`frameLocator(${JSON.stringify(selector)}) found no frames`)
    const next: number[] = []
    for (const backendNodeId of frames) {
      const described = await runtime.connection.send<{
        node: { contentDocument?: { backendNodeId?: number } }
      }>("DOM.describeNode", { backendNodeId, depth: 1, pierce: true }, page.sessionId)
      const contentDocument = described.node.contentDocument?.backendNodeId
      if (contentDocument === undefined) {
        throw new Error(
          `frameLocator(${JSON.stringify(selector)}) cannot access that frame document`
        )
      }
      next.push(contentDocument)
    }
    current = [...new Set(next)]
  }
  return current
}

const semanticLocatorFunction =
  "function(kind,expected,exact){const normalize=value=>String(value??'').replace(/\\s+/g,' ').trim();const matches=value=>{const actual=normalize(value);if(expected&&typeof expected==='object'&&typeof expected.regex==='string')return new RegExp(expected.regex,expected.flags||'').test(actual);return exact?actual===expected:actual.toLocaleLowerCase().includes(String(expected).toLocaleLowerCase());};if(kind==='label')return [...this.querySelectorAll('input,textarea,select,button,[contenteditable=true]')].filter(element=>{const doc=element.ownerDocument;const labelledBy=(element.getAttribute('aria-labelledby')||'').split(/\\s+/).filter(Boolean).map(id=>doc.getElementById(id)?.innerText||'').join(' ');const labels=element.labels?[...element.labels].map(label=>{const clone=label.cloneNode(true);clone.querySelectorAll('input,textarea,select,button,option,[contenteditable=true]').forEach(control=>control.remove());return clone.textContent||'';}):[];return[element.getAttribute('aria-label'),labelledBy,...labels].some(matches);});if(kind==='placeholder')return[...this.querySelectorAll('[placeholder]')].filter(element=>matches(element.getAttribute('placeholder')));if(kind==='testId')return[...this.querySelectorAll('[data-testid]')].filter(element=>matches(element.getAttribute('data-testid')));const candidates=[...this.querySelectorAll('*')].filter(element=>matches(element.innerText||element.textContent));return candidates.filter(element=>![...element.children].some(child=>matches(child.innerText||child.textContent))).slice(0,200);}" as const

const callBackendNodePredicate = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  backendNodeId: number,
  functionDeclaration: string,
  args: ReadonlyArray<unknown> = []
): Promise<boolean> => {
  const resolved = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId },
    page.sessionId
  )
  const objectId = resolved.object.objectId
  if (objectId === undefined) return false
  try {
    return evaluatedValue<boolean>(
      await runtime.connection.send(
        "Runtime.callFunctionOn",
        {
          objectId,
          functionDeclaration,
          arguments: args.map((value) => ({ value })),
          returnByValue: true
        },
        page.sessionId
      )
    )
  } finally {
    await runtime.connection
      .send("Runtime.releaseObject", { objectId }, page.sessionId)
      .catch(() => undefined)
  }
}

const locatorBackendNodeIds = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  value: unknown,
  inheritedRoots?: ReadonlyArray<number>,
  depth = 0
): Promise<number[]> => {
  if (depth > 12) throw new Error("locator composition is too deeply nested")
  const locator = parseLocator(value, depth)
  let roots =
    inheritedRoots === undefined
      ? [await mainDocumentBackendNodeId(runtime, page)]
      : [...inheritedRoots]
  if (locator.frame !== undefined && locator.frame.length > 0) {
    roots = await resolveFrameRoots(runtime, page, roots, locator.frame)
  }
  if (locator.scope !== undefined) {
    roots = await locatorBackendNodeIds(runtime, page, locator.scope, roots, depth + 1)
  }
  let ids: number[]
  if (locator.ref !== undefined) {
    const snapshot = runtime.snapshots.get(page.target.targetId)
    if (snapshot === undefined) {
      throw new Error("No current Browser Use snapshot; call playwright.domSnapshot first")
    }
    const ref = normalizeRef(locator.ref)
    const id = snapshot.targets.get(ref)
    ids = id === undefined ? [] : await filterBackendNodeIdsByRoots(runtime, page, [id], roots)
  } else if (locator.css !== undefined) {
    ids = await queryCssWithinRoots(runtime, page, roots, locator.css)
  } else if (locator.role !== undefined) {
    const response = await runtime.connection.send<{ nodes: AXNode[] }>(
      "Accessibility.getFullAXTree",
      {},
      page.sessionId
    )
    const role = locator.role.toLocaleLowerCase()
    const expectedName = locator.name
    const exact = locator.exact === true
    const candidates = [
      ...new Set(
        response.nodes
          .filter((node) => {
            if (node.ignored || node.backendDOMNodeId === undefined) return false
            if (String(node.role?.value ?? "").toLocaleLowerCase() !== role) return false
            if (expectedName === undefined) return true
            const actual = String(node.name?.value ?? "")
              .replace(/\s+/g, " ")
              .trim()
            if (typeof expectedName !== "string") {
              return new RegExp(expectedName.regex, expectedName.flags).test(actual)
            }
            return exact
              ? actual === expectedName
              : actual.toLocaleLowerCase().includes(expectedName.toLocaleLowerCase())
          })
          .map((node) => node.backendDOMNodeId!)
      )
    ]
    ids = await filterBackendNodeIdsByRoots(runtime, page, candidates, roots)
  } else {
    const kind =
      locator.label !== undefined
        ? "label"
        : locator.placeholder !== undefined
          ? "placeholder"
          : locator.testId !== undefined
            ? "testId"
            : "text"
    const expected = locator.label ?? locator.placeholder ?? locator.testId ?? locator.text ?? ""
    const exact = locator.testId !== undefined || locator.exact === true
    const matches = await Promise.all(
      roots.map((root) =>
        backendNodeIdsFromRootFunction(runtime, page, root, semanticLocatorFunction, [
          kind,
          expected,
          exact
        ])
      )
    )
    ids = [...new Set(matches.flat())]
  }

  const filters = locator.filters
  if (filters !== undefined) {
    const filtered: number[] = []
    for (const id of ids) {
      const textMatches = await callBackendNodePredicate(
        runtime,
        page,
        id,
        "function(hasText,hasNotText,visible){const text=String(this.innerText||this.textContent||'').replace(/\\s+/g,' ').trim();const matches=expected=>expected&&typeof expected==='object'&&typeof expected.regex==='string'?new RegExp(expected.regex,expected.flags||'').test(text):text.toLocaleLowerCase().includes(String(expected).toLocaleLowerCase());const shown=(()=>{const r=this.getBoundingClientRect(),s=getComputedStyle(this);return this.isConnected&&r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';})();return(hasText===null||matches(hasText))&&(hasNotText===null||!matches(hasNotText))&&(visible===null||shown===visible);}",
        [filters.hasText ?? null, filters.hasNotText ?? null, filters.visible ?? null]
      )
      if (!textMatches) continue
      if (
        filters.has !== undefined &&
        (await locatorBackendNodeIds(runtime, page, filters.has, [id], depth + 1)).length === 0
      ) {
        continue
      }
      if (
        filters.hasNot !== undefined &&
        (await locatorBackendNodeIds(runtime, page, filters.hasNot, [id], depth + 1)).length > 0
      ) {
        continue
      }
      filtered.push(id)
    }
    ids = filtered
  }
  if (locator.and !== undefined) {
    const other = new Set(
      await locatorBackendNodeIds(runtime, page, locator.and, undefined, depth + 1)
    )
    ids = ids.filter((id) => other.has(id))
  }
  if (locator.or !== undefined) {
    ids = [
      ...new Set([
        ...ids,
        ...(await locatorBackendNodeIds(runtime, page, locator.or, undefined, depth + 1))
      ])
    ]
  }
  if (locator.index !== undefined) {
    const index = locator.index === "last" ? ids.length - 1 : locator.index
    ids = index < 0 || index >= ids.length ? [] : [ids[index]!]
  }
  return ids
}

const resolveBackendElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  backendNodeId: number,
  targetLabel: string,
  requireActionable: boolean
): Promise<ResolvedElement> => {
  const resolved = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId },
    page.sessionId
  )
  const objectId = resolved.object.objectId
  if (objectId === undefined) throw new Error(`${targetLabel} is no longer attached`)
  try {
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId,
        functionDeclaration:
          "function(){ this.scrollIntoView({block:'center',inline:'center',behavior:'instant'}); }",
        returnByValue: true
      },
      page.sessionId
    )
    await delay(50)
    const state = evaluatedValue<{
      connected: boolean
      visible: boolean
      disabled: boolean
      hit: boolean
    }>(
      await runtime.connection.send(
        "Runtime.callFunctionOn",
        {
          objectId,
          functionDeclaration:
            "function(){const r=this.getBoundingClientRect();const s=getComputedStyle(this);const h=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);return {connected:this.isConnected,visible:r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'&&s.pointerEvents!=='none',disabled:!!this.disabled||this.getAttribute('aria-disabled')==='true',hit:h===this||this.contains(h)};}",
          returnByValue: true
        },
        page.sessionId
      )
    )
    if (!state.connected) throw new Error(`${targetLabel} detached`)
    if (!state.visible) throw new Error(`${targetLabel} is not visible after scrolling`)
    if (requireActionable && state.disabled) throw new Error(`${targetLabel} is disabled`)
    if (requireActionable && !state.hit)
      throw new Error(`${targetLabel} is obscured at its action point`)
    const model = await runtime.connection.send<{
      model: { content: number[]; border: number[]; width: number; height: number }
    }>("DOM.getBoxModel", { backendNodeId }, page.sessionId)
    const quad = model.model.border.length >= 8 ? model.model.border : model.model.content
    const x = (quad[0]! + quad[2]! + quad[4]! + quad[6]!) / 4
    const y = (quad[1]! + quad[3]! + quad[5]! + quad[7]!) / 4
    return {
      backendNodeId,
      objectId,
      x,
      y,
      width: model.model.width,
      height: model.model.height
    }
  } catch (cause) {
    await runtime.connection
      .send("Runtime.releaseObject", { objectId }, page.sessionId)
      .catch(() => undefined)
    throw cause
  }
}

const resolveLocatorElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  locator: unknown,
  requireActionable = true,
  timeoutMs = 30_000
): Promise<ResolvedElement> => {
  const deadline = Date.now() + Math.max(0, Math.min(30_000, timeoutMs))
  let lastError = "Playwright locator resolved to 0 elements"
  while (true) {
    const ids = await locatorBackendNodeIds(runtime, page, locator)
    if (ids.length > 1) {
      throw new Error(
        `Playwright strict mode violation: locator resolved to ${ids.length} elements`
      )
    }
    if (ids.length === 1) {
      try {
        return await resolveBackendElement(
          runtime,
          page,
          ids[0]!,
          "Playwright locator",
          requireActionable
        )
      } catch (cause) {
        lastError = cause instanceof Error ? cause.message : String(cause)
      }
    }
    if (Date.now() >= deadline) throw new Error(lastError)
    await delay(100)
  }
}

const resolveElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  target: unknown,
  requireActionable = true
): Promise<ResolvedElement> => {
  const snapshot = runtime.snapshots.get(page.target.targetId)
  if (snapshot === undefined)
    throw new Error("No current Browser Use snapshot; call snapshot first")
  const ref = normalizeRef(target)
  const backendNodeId = snapshot.targets.get(ref)
  if (backendNodeId === undefined) {
    throw new Error(`Unknown or stale target ${ref}; call snapshot again and use a current ref`)
  }
  return resolveBackendElement(runtime, page, backendNodeId, `Target ${ref}`, requireActionable)
}

const releaseElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement
): Promise<void> => {
  // Runtime commands are suspended while a JavaScript modal is open. The remote object is
  // reclaimed with its execution context, so avoid holding the click tool open while the caller
  // needs to issue Page.handleJavaScriptDialog.
  if (runtime.dialogs.has(page.sessionId)) return
  await runtime.connection
    .send("Runtime.releaseObject", { objectId: element.objectId }, page.sessionId)
    .catch(() => undefined)
}

const dispatchClick = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  x: number,
  y: number,
  button: string,
  count: number,
  modifiers = 0
): Promise<void> => {
  const normalized = button === "right" || button === "middle" ? button : "left"
  const buttonMask = normalized === "left" ? 1 : normalized === "right" ? 2 : 4
  const dispatch = async (
    params: Readonly<Record<string, unknown>>
  ): Promise<{ readonly dialogOpened: boolean; readonly completion: Promise<void> }> => {
    let resolveDialog = (): void => undefined
    const dialog = new Promise<void>((resolve) => {
      resolveDialog = resolve
    })
    const stop = runtime.connection.on(
      "Page.javascriptDialogOpening",
      () => resolveDialog(),
      page.sessionId
    )
    const command = runtime.connection
      .send("Input.dispatchMouseEvent", params, page.sessionId)
      .then(() => undefined)
    try {
      const outcome = await Promise.race([
        command.then(() => "completed" as const),
        dialog.then(() => "dialog" as const)
      ])
      if (outcome === "completed") return { dialogOpened: false, completion: command }
      // Chrome deliberately keeps the input command pending while a modal JavaScript dialog is
      // open. Return the click as delivered so the next tool call can inspect and handle the
      // dialog; accepting or dismissing it lets this command finish in the background.
      const completion = command.catch(() => undefined)
      return { dialogOpened: true, completion }
    } finally {
      stop()
    }
  }

  const moved = await dispatch({ type: "mouseMoved", x, y, modifiers })
  if (moved.dialogOpened) return
  for (let clickCount = 1; clickCount <= count; clickCount++) {
    const pressed = await dispatch({
      type: "mousePressed",
      x,
      y,
      button: normalized,
      buttons: buttonMask,
      clickCount,
      modifiers
    })
    if (pressed.dialogOpened) {
      void pressed.completion.then(() =>
        runtime.connection
          .send(
            "Input.dispatchMouseEvent",
            {
              type: "mouseReleased",
              x,
              y,
              button: normalized,
              buttons: 0,
              clickCount,
              modifiers
            },
            page.sessionId
          )
          .then(() => undefined)
          .catch(() => undefined)
      )
      return
    }
    await delay(25)
    const released = await dispatch({
      type: "mouseReleased",
      x,
      y,
      button: normalized,
      buttons: 0,
      clickCount,
      modifiers
    })
    if (released.dialogOpened) return
    if (clickCount < count) await delay(80)
  }
}

const triggerMediaDownload = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  objectId: string
): Promise<void> => {
  const result = evaluatedValue<{ error?: string }>(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId,
        functionDeclaration:
          "function(){const url=this.currentSrc||this.src||this.href;if(!url)return{error:'The target has no media URL'};const link=document.createElement('a');link.href=url;link.download='';link.style.display='none';document.body.append(link);link.click();link.remove();return{};}",
        returnByValue: true,
        userGesture: true
      },
      page.sessionId
    )
  )
  if (result.error !== undefined) throw new Error(result.error)
}

const mediaElementAtPoint = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  x: number,
  y: number
): Promise<string> => {
  const evaluated = await runtime.connection.send<{ result: { objectId?: string } }>(
    "Runtime.evaluate",
    {
      expression: `document.elementFromPoint(${JSON.stringify(x)},${JSON.stringify(y)})`,
      returnByValue: false
    },
    page.sessionId
  )
  const objectId = evaluated.result.objectId
  if (objectId === undefined) throw new Error("No element exists at that viewport coordinate")
  return objectId
}

const actionResult = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  action: string,
  extra: Readonly<Record<string, unknown>> = {}
): Promise<CallToolResult> => {
  await delay(100)
  return pageResult(runtime, page, {
    action,
    path: "cdp",
    delivered: true,
    verified: false,
    effect: "unverifiable",
    next: "Call snapshot to confirm the effect and obtain fresh refs.",
    ...extra
  })
}

const verifiedActionResult = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  action: string,
  extra: Readonly<Record<string, unknown>> = {}
): Promise<CallToolResult> => {
  await delay(50)
  return pageResult(runtime, page, {
    action,
    path: "cdp",
    delivered: true,
    verified: true,
    effect: "confirmed",
    ...extra
  })
}

const fillResolvedElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement,
  text: string,
  slowly: boolean,
  replace: boolean
): Promise<string | undefined> => {
  const preparation = evaluatedValue<{
    actual?: string
    error?: string
    needsInput?: boolean
    type?: string
  }>(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId: element.objectId,
        functionDeclaration:
          "function(value,replace){const tag=this.tagName?.toLowerCase();const type=tag==='input'?String(this.type||'text').toLowerCase():tag;const setValueTypes=new Set(['color','date','time','datetime-local','month','range','week']);const typeableTypes=new Set(['text','email','number','password','search','tel','url']);if(tag==='input'){if(!typeableTypes.has(type)&&!setValueTypes.has(type))return {error:`Input type ${type} cannot be filled`,type};if(type==='number'&&Number.isNaN(Number(String(value).trim())))return {error:'Cannot type text into input[type=number]',type};if(setValueTypes.has(type)){const normalized=String(value).trim();this.focus();this.value=type==='color'?normalized.toLowerCase():normalized;if(this.value!==normalized.toLowerCase())return {error:`Malformed value for input[type=${type}]`,actual:this.value,type};this.dispatchEvent(new Event('input',{bubbles:true,composed:true}));this.dispatchEvent(new Event('change',{bubbles:true}));return {actual:this.value,type};}}else if(tag!=='textarea'&&!this.isContentEditable)return {error:'Element is not an <input>, <textarea> or [contenteditable] element',type};this.focus();if(replace){if(typeof this.select==='function')this.select();else{const selection=getSelection(),range=document.createRange();range.selectNodeContents(this);selection.removeAllRanges();selection.addRange(range);}}return {needsInput:true,type};}",
        arguments: [{ value: text }, { value: replace }],
        returnByValue: true
      },
      page.sessionId
    )
  )
  if (preparation.error !== undefined) throw new Error(preparation.error)
  if (preparation.needsInput === true) {
    if (slowly) {
      for (const character of text) {
        await runtime.connection.send("Input.insertText", { text: character }, page.sessionId)
        await delay(35)
      }
    } else await runtime.connection.send("Input.insertText", { text }, page.sessionId)
  }
  const actual = evaluatedValue<string | undefined>(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId: element.objectId,
        functionDeclaration:
          "function(){if(this.tagName?.toLowerCase()==='input'||this.tagName?.toLowerCase()==='textarea')return String(this.value);if(this.isContentEditable)return String(this.textContent||'');return undefined;}",
        returnByValue: true
      },
      page.sessionId
    )
  )
  if (replace && actual !== text && preparation.actual === undefined) {
    throw new Error(
      `Browser fill verification failed: expected ${JSON.stringify(text)}, received ${JSON.stringify(actual)}`
    )
  }
  return actual
}

const fillElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  target: unknown,
  text: string,
  slowly: boolean
): Promise<void> => {
  const element = await resolveElement(runtime, page, target)
  try {
    await fillResolvedElement(runtime, page, element, text, slowly, true)
  } finally {
    await releaseElement(runtime, page, element)
  }
}

const checkedState = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement
): Promise<{ checked?: boolean; error?: string; radio?: boolean }> =>
  evaluatedValue(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId: element.objectId,
        functionDeclaration:
          "function(){const tag=this.tagName?.toLowerCase(),type=String(this.type||'').toLowerCase();if(tag!=='input'||(type!=='checkbox'&&type!=='radio'))return {error:'Element is not a checkbox or radio button'};return {checked:!!this.checked,radio:type==='radio'};}",
        returnByValue: true
      },
      page.sessionId
    )
  )

const setCheckedElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement,
  desired: boolean
): Promise<void> => {
  const before = await checkedState(runtime, page, element)
  if (before.error !== undefined) throw new Error(before.error)
  if (before.checked === desired) return
  if (before.radio === true && !desired) {
    throw new Error("Radio buttons can only be unchecked by selecting another radio button")
  }
  await dispatchClick(runtime, page, element.x, element.y, "left", 1)
  const after = await checkedState(runtime, page, element)
  if (after.checked !== desired) {
    throw new Error(`Clicking the control did not change its checked state to ${desired}`)
  }
}

const selectOptionsElement = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  element: ResolvedElement,
  values: ReadonlyArray<unknown>
): Promise<string[]> => {
  const result = evaluatedValue<{ error?: string; selected?: string[] }>(
    await runtime.connection.send(
      "Runtime.callFunctionOn",
      {
        objectId: element.objectId,
        functionDeclaration:
          "function(values){if(this.tagName?.toLowerCase()!=='select')return {error:'Element is not a <select> element'};const options=[...this.options],selected=[];for(const requested of values){const spec=typeof requested==='string'?{valueOrLabel:requested}:requested||{};const option=options.find((candidate,index)=>(spec.valueOrLabel===undefined||(candidate.value===spec.valueOrLabel||candidate.label===spec.valueOrLabel))&&(spec.value===undefined||candidate.value===spec.value)&&(spec.label===undefined||candidate.label===spec.label)&&(spec.index===undefined||index===spec.index));if(!option)return {error:`Option not found: ${JSON.stringify(requested)}`};if(option.disabled)return {error:`Option is disabled: ${option.label}`};if(!selected.includes(option))selected.push(option);}if(!this.multiple&&selected.length>1)return {error:'A single-select control cannot select multiple options'};for(const option of options)option.selected=selected.includes(option);this.dispatchEvent(new Event('input',{bubbles:true,composed:true}));this.dispatchEvent(new Event('change',{bubbles:true}));return {selected:[...this.selectedOptions].map(option=>option.value)};}",
        arguments: [{ value: values }],
        returnByValue: true
      },
      page.sessionId
    )
  )
  if (result.error !== undefined) throw new Error(result.error)
  return result.selected ?? []
}

const callLocatorFunction = async <T>(
  runtime: BrowserRuntime,
  page: PageHandle,
  locator: unknown,
  functionDeclaration: string,
  args: ReadonlyArray<unknown> = [],
  timeoutMs = 30_000
): Promise<T> => {
  const deadline = Date.now() + Math.max(0, Math.min(30_000, timeoutMs))
  let ids: number[] = []
  while (true) {
    ids = await locatorBackendNodeIds(runtime, page, locator)
    if (ids.length === 1) break
    if (ids.length > 1) {
      throw new Error(
        `Playwright strict mode violation: locator resolved to ${ids.length} elements`
      )
    }
    if (Date.now() >= deadline) throw new Error("Playwright locator resolved to 0 elements")
    await delay(100)
  }
  const resolved = await runtime.connection.send<{ object: { objectId?: string } }>(
    "DOM.resolveNode",
    { backendNodeId: ids[0] },
    page.sessionId
  )
  const objectId = resolved.object.objectId
  if (objectId === undefined) throw new Error("Playwright locator is no longer attached")
  try {
    return evaluatedValue<T>(
      await runtime.connection.send(
        "Runtime.callFunctionOn",
        {
          objectId,
          functionDeclaration,
          arguments: args.map((value) => ({ value })),
          returnByValue: true
        },
        page.sessionId
      )
    )
  } finally {
    await runtime.connection
      .send("Runtime.releaseObject", { objectId }, page.sessionId)
      .catch(() => undefined)
  }
}

const locatorIsVisible = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  locator: unknown
): Promise<boolean> => {
  const ids = await locatorBackendNodeIds(runtime, page, locator)
  if (ids.length === 0) return false
  if (ids.length > 1) {
    throw new Error(`Playwright strict mode violation: locator resolved to ${ids.length} elements`)
  }
  return callLocatorFunction<boolean>(
    runtime,
    page,
    locator,
    "function(){const r=this.getBoundingClientRect(),s=getComputedStyle(this);return this.isConnected&&r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';}"
  )
}

export const browserKeyDescription = (
  value: string
): {
  key: string
  code: string
  windowsVirtualKeyCode: number
  modifiers: number
  text?: string
} => {
  const parts = value
    .split("+")
    .map((part) => part.trim())
    .filter(Boolean)
  if (parts.length === 0) throw new Error("key is required")
  let modifiers = 0
  for (const modifier of parts.slice(0, -1)) {
    switch (modifier.toLowerCase()) {
      case "alt":
      case "option":
        modifiers |= 1
        break
      case "ctrl":
      case "control":
        modifiers |= 2
        break
      case "controlormeta":
        modifiers |= process.platform === "darwin" ? 4 : 2
        break
      case "meta":
      case "cmd":
      case "command":
        modifiers |= 4
        break
      case "shift":
        modifiers |= 8
        break
      default:
        throw new Error(`Unsupported key modifier: ${modifier}`)
    }
  }
  const raw = parts.at(-1)!
  const named: Readonly<Record<string, [string, string, number]>> = {
    enter: ["Enter", "Enter", 13],
    return: ["Enter", "Enter", 13],
    tab: ["Tab", "Tab", 9],
    escape: ["Escape", "Escape", 27],
    esc: ["Escape", "Escape", 27],
    backspace: ["Backspace", "Backspace", 8],
    delete: ["Delete", "Delete", 46],
    space: [" ", "Space", 32],
    spacebar: [" ", "Space", 32],
    left: ["ArrowLeft", "ArrowLeft", 37],
    arrowleft: ["ArrowLeft", "ArrowLeft", 37],
    right: ["ArrowRight", "ArrowRight", 39],
    arrowright: ["ArrowRight", "ArrowRight", 39],
    up: ["ArrowUp", "ArrowUp", 38],
    arrowup: ["ArrowUp", "ArrowUp", 38],
    down: ["ArrowDown", "ArrowDown", 40],
    arrowdown: ["ArrowDown", "ArrowDown", 40],
    home: ["Home", "Home", 36],
    end: ["End", "End", 35],
    pageup: ["PageUp", "PageUp", 33],
    pagedown: ["PageDown", "PageDown", 34]
  }
  const match = named[raw.toLowerCase()]
  if (match !== undefined)
    return { key: match[0], code: match[1], windowsVirtualKeyCode: match[2], modifiers }
  if ([...raw].length !== 1) throw new Error(`Unsupported key: ${raw}`)
  const upper = raw.toUpperCase()
  const letter = /^[A-Z]$/.test(upper)
  const code = letter ? `Key${upper}` : /^[0-9]$/.test(raw) ? `Digit${raw}` : raw
  const key = (modifiers & 8) !== 0 ? upper : raw
  return {
    key,
    code,
    windowsVirtualKeyCode: upper.codePointAt(0)!,
    modifiers,
    ...((modifiers & (2 | 4)) === 0 ? { text: key } : {})
  }
}

const mouseModifierMask = (value: unknown): number => {
  if (value === undefined) return 0
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === "string")) {
    throw new Error("modifiers must be an array of keyboard modifier names")
  }
  let mask = 0
  for (const entry of value) {
    switch (entry.toLocaleLowerCase()) {
      case "alt":
      case "option":
        mask |= 1
        break
      case "control":
      case "ctrl":
        mask |= 2
        break
      case "controlormeta":
        mask |= process.platform === "darwin" ? 4 : 2
        break
      case "meta":
      case "cmd":
      case "command":
        mask |= 4
        break
      case "shift":
        mask |= 8
        break
      default:
        throw new Error(`Unsupported mouse modifier: ${entry}`)
    }
  }
  return mask
}

const pressKey = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  value: string
): Promise<void> => {
  const key = browserKeyDescription(value)
  await runtime.connection.send(
    "Input.dispatchKeyEvent",
    { type: key.text === undefined ? "rawKeyDown" : "keyDown", ...key },
    page.sessionId
  )
  await runtime.connection.send(
    "Input.dispatchKeyEvent",
    {
      type: "keyUp",
      key: key.key,
      code: key.code,
      windowsVirtualKeyCode: key.windowsVirtualKeyCode,
      modifiers: key.modifiers
    },
    page.sessionId
  )
}

const numberArgument = (args: Readonly<Record<string, unknown>>, name: string): number => {
  const value = args[name]
  if (typeof value !== "number" || !Number.isFinite(value))
    throw new Error(`${name} must be a number`)
  return value
}

const stringArgument = (args: Readonly<Record<string, unknown>>, name: string): string => {
  const value = args[name]
  if (typeof value !== "string") throw new Error(`${name} must be a string`)
  return value
}

const booleanArgument = (args: Readonly<Record<string, unknown>>, name: string): boolean => {
  const value = args[name]
  if (typeof value !== "boolean") throw new Error(`${name} must be a boolean`)
  return value
}

const userChromiumIsRunning = (): boolean => {
  if (process.env.CODEVISOR_BROWSER_CDP_URL !== undefined) return true
  if (process.platform !== "darwin" && process.platform !== "linux") return false
  const names =
    process.platform === "darwin"
      ? ["Google Chrome", "Chromium", "Brave Browser", "Microsoft Edge"]
      : ["google-chrome", "chromium", "chromium-browser", "brave-browser", "microsoft-edge"]
  return names.some((name) => spawnSync("pgrep", ["-x", name], { stdio: "ignore" }).status === 0)
}

export const makeBrowserUseProvider = (dataDir: string): BrowserUseProvider => {
  const browsersDir = join(dataDir, "browser", "browsers")
  const profilesDir = join(dataDir, "browser", "profiles")
  const downloadsDir = join(dataDir, "browser", "downloads")
  const assetsDir = join(dataDir, "browser", "assets")
  mkdirSync(browsersDir, { recursive: true, mode: 0o700 })
  mkdirSync(profilesDir, { recursive: true, mode: 0o700 })
  mkdirSync(downloadsDir, { recursive: true, mode: 0o700 })
  mkdirSync(assetsDir, { recursive: true, mode: 0o700 })
  const runtimes = new Map<string, Promise<BrowserRuntime>>()
  const sessionBackends = new Map<string, BrowserBackend>()
  const selectedTargets = new Map<string, string>()
  const sessionTargets = new Map<string, Map<string, "created" | "claimed">>()
  const sessionDispositions = new Map<string, Map<string, "deliverable" | "handoff">>()
  const assetInventories = new Map<
    string,
    {
      readonly pageUrl: string
      readonly assets: ReadonlyArray<{
        readonly id: string
        readonly url: string
        readonly kind: string
        readonly name: string
        readonly sources: ReadonlyArray<Readonly<Record<string, unknown>>>
      }>
      readonly inlineSvgs: ReadonlyArray<{
        readonly id: string
        readonly markup: string
        readonly name: string
      }>
    }
  >()
  const extensionRelay = makeBrowserExtensionRelay()
  const developmentExtensionPath = prepareBrowserExtension(dataDir, "http://127.0.0.1:49361")
  const extensionArchive = browserExtensionArchivePath(developmentExtensionPath)
  const extensionSetupMode: BrowserExtensionSetupMode =
    process.env.CODEVISOR_DEV_WORKTREE !== undefined ||
    process.env.HERDMAN_DEV_WORKTREE !== undefined
      ? "development"
      : "webStore"
  const stopRelayLifecycle = extensionRelay.onConnectionChange((connected) => {
    if (!connected) runtimes.delete("extension")
  })
  let setupPromise: Promise<void> | undefined
  let setupError: string | undefined

  const extensionEndpoint = (): string | undefined => process.env.CODEVISOR_BROWSER_CDP_URL
  const status = () => {
    const extension = browserExtensionInstallation()
    return {
      engine: "codevisor-cdp",
      backend:
        systemChromePath() !== undefined
          ? "systemChrome"
          : downloadedChromiumPath(browsersDir) !== undefined
            ? "downloadedChromium"
            : "missing",
      extensionAvailable: extension.bundled,
      extensionInstalled: extension.installed,
      extensionInstallationState: extension.installationState,
      extensionConnected: extensionEndpoint() !== undefined || extensionRelay.connected(),
      extensionSetupMode,
      chromeAvailable: chromeBrowserAvailable(),
      developmentExtensionPath,
      extensionArchivePath: extensionArchive,
      userBrowserOpen: userChromiumIsRunning(),
      installing: setupPromise !== undefined,
      ...(setupError === undefined ? {} : { error: setupError })
    }
  }

  const ensureSetup = async (): Promise<void> => {
    if (systemChromePath() !== undefined || downloadedChromiumPath(browsersDir) !== undefined)
      return
    if (setupPromise !== undefined) return setupPromise
    setupError = undefined
    setupPromise = runBrowserInstaller(browsersDir)
      .catch((cause) => {
        setupError = cause instanceof Error ? cause.message : String(cause)
        throw cause
      })
      .finally(() => {
        setupPromise = undefined
      })
    return setupPromise
  }

  const profileKey = (context: AutomationProviderContext): string =>
    createHash("sha256")
      .update(context.projectId ?? "global")
      .digest("hex")
      .slice(0, 24)

  const runtimeKey = (context: AutomationProviderContext, backend: BrowserBackend): string =>
    backend === "managed" ? `managed:${context.projectId ?? "global"}` : "extension"

  const createRuntime = async (
    context: AutomationProviderContext,
    backend: BrowserBackend
  ): Promise<BrowserRuntime> => {
    let connection: CdpConnection
    let processHandle: ChildProcess | undefined
    let owned = false
    if (backend === "extension") {
      const endpoint = extensionEndpoint()
      connection =
        endpoint === undefined
          ? await extensionRelay.connect()
          : await CdpConnection.connect(endpoint)
    } else {
      await ensureSetup()
      const executablePath = systemChromePath() ?? downloadedChromiumPath(browsersDir)
      if (executablePath === undefined) throw new Error("No managed Chromium is installed")
      const profileDir = join(profilesDir, profileKey(context))
      mkdirSync(profileDir, { recursive: true, mode: 0o700 })
      const launched = await launchManagedBrowser(executablePath, profileDir)
      connection = launched.connection
      processHandle = launched.processHandle
      owned = launched.processHandle !== undefined
    }
    await connection.send("Target.setDiscoverTargets", { discover: true })
    const active: BrowserRuntime = {
      connection,
      processHandle,
      owned,
      sessions: new Map(),
      snapshots: new Map(),
      eventLog: [],
      logs: new Map(),
      dialogs: new Map(),
      fileChoosers: new Map(),
      downloads: new Map(),
      eventDisposers: [],
      eventSequence: 0,
      tabOrder: [],
      queue: Promise.resolve()
    }
    active.eventDisposers.push(
      connection.on("*", (params, event) => {
        const sequence = ++active.eventSequence
        active.eventLog.push({
          method: event.method,
          params,
          sequence,
          ...(event.sessionId === undefined ? {} : { sessionId: event.sessionId })
        })
        if (active.eventLog.length > 5_000)
          active.eventLog.splice(0, active.eventLog.length - 5_000)
        if (event.sessionId !== undefined) {
          if (
            event.method === "Runtime.consoleAPICalled" ||
            event.method === "Runtime.exceptionThrown" ||
            event.method === "Log.entryAdded"
          ) {
            const entries = active.logs.get(event.sessionId) ?? []
            entries.push({ method: event.method, ...params, sequence })
            if (entries.length > 1_000) entries.splice(0, entries.length - 1_000)
            active.logs.set(event.sessionId, entries)
          } else if (event.method === "Page.javascriptDialogOpening") {
            active.dialogs.set(event.sessionId, { ...params })
          } else if (event.method === "Page.javascriptDialogClosed") {
            active.dialogs.delete(event.sessionId)
          }
        }
        if (
          event.method === "Browser.downloadWillBegin" ||
          event.method === "Page.downloadWillBegin"
        ) {
          const guid = typeof params.guid === "string" ? params.guid : randomUUID()
          active.downloads.set(guid, {
            guid,
            url: String(params.url ?? ""),
            suggestedFilename: String(params.suggestedFilename ?? "download"),
            ...(typeof params.filePath === "string" ? { path: params.filePath } : {})
          })
        } else if (
          (event.method === "Browser.downloadProgress" ||
            event.method === "Page.downloadProgress") &&
          typeof params.guid === "string"
        ) {
          const existing = active.downloads.get(params.guid)
          if (existing !== undefined) {
            active.downloads.set(params.guid, {
              ...existing,
              ...(typeof params.state === "string"
                ? { state: params.state }
                : existing.state === undefined
                  ? {}
                  : { state: existing.state }),
              ...(typeof params.filePath === "string"
                ? { path: params.filePath }
                : params.state === "completed" && existing.path === undefined
                  ? { path: join(downloadsDir, params.guid) }
                  : {})
            })
          }
        }
      })
    )
    return active
  }

  const runtime = (
    context: AutomationProviderContext,
    backend: BrowserBackend
  ): Promise<BrowserRuntime> => {
    const key = runtimeKey(context, backend)
    const existing = runtimes.get(key)
    if (existing !== undefined) return existing
    const created = createRuntime(context, backend).catch((cause) => {
      runtimes.delete(key)
      throw cause
    })
    runtimes.set(key, created)
    return created
  }

  const extensionConnectionResult = (): CallToolResult =>
    jsonResult({
      backend: "extension",
      connectionState:
        extensionEndpoint() !== undefined || extensionRelay.connected()
          ? "connected"
          : "needs_setup",
      connected: extensionEndpoint() !== undefined || extensionRelay.connected(),
      next:
        extensionEndpoint() !== undefined || extensionRelay.connected()
          ? "Call openTabs, then claimTab before inspecting or changing a page."
          : "Chrome is not connected. Codevisor handles browser selection and extension setup in the composer."
    })

  const serialized = async <T>(active: BrowserRuntime, operation: () => Promise<T>): Promise<T> => {
    let release = (): void => undefined
    const previous = active.queue
    active.queue = new Promise<void>((resolve) => {
      release = resolve
    })
    await previous
    try {
      return await operation()
    } finally {
      release()
    }
  }

  const invokeTool = async (
    context: AutomationProviderContext,
    active: BrowserRuntime,
    toolName: string,
    args: Readonly<Record<string, unknown>>
  ): Promise<CallToolResult> => {
    const backend = sessionBackends.get(context.sessionId) ?? "managed"
    const sessionKey = `${runtimeKey(context, backend)}:${context.sessionId}`
    if (toolName === "finalizeTabs") {
      if (args.native === true) {
        if (
          args.keepIds !== undefined &&
          (!Array.isArray(args.keepIds) ||
            !args.keepIds.every((value) => typeof value === "string"))
        ) {
          throw new Error("keepIds must be an array of tab ids")
        }
        const keepIds = new Set([
          ...((args.keepIds as string[] | undefined) ?? []),
          ...(sessionDispositions.get(sessionKey)?.keys() ?? [])
        ])
        const controlled = sessionTargets.get(sessionKey) ?? new Map()
        for (const [targetId, origin] of controlled) {
          const tabSessionId = active.sessions.get(targetId)
          if (origin === "created" && !keepIds.has(targetId)) {
            await active.connection.send("Target.closeTarget", { targetId }).catch(() => undefined)
          } else if (tabSessionId !== undefined) {
            await active.connection
              .send("Target.detachFromTarget", { sessionId: tabSessionId })
              .catch(() => undefined)
          }
          active.sessions.delete(targetId)
          active.snapshots.delete(targetId)
        }
        sessionTargets.delete(sessionKey)
        sessionDispositions.delete(sessionKey)
        selectedTargets.delete(sessionKey)
        return jsonResult({ finalized: true, kept: [...keepIds] })
      }
      const targetId = selectedTargets.get(sessionKey)
      if (targetId === undefined) return jsonResult({ finalized: true, tabsClosed: false })
      const tabSessionId = active.sessions.get(targetId)
      if (args.close === true) {
        await active.connection.send("Target.closeTarget", { targetId })
      } else if (tabSessionId !== undefined) {
        await active.connection.send("Target.detachFromTarget", { sessionId: tabSessionId })
      }
      active.sessions.delete(targetId)
      active.snapshots.delete(targetId)
      sessionTargets.get(sessionKey)?.delete(targetId)
      selectedTargets.delete(sessionKey)
      return jsonResult({ finalized: true, tabsClosed: args.close === true })
    }
    if (toolName === "markTab") {
      const status = stringArgument(args, "status")
      if (status !== "deliverable" && status !== "handoff") {
        throw new Error("status must be deliverable or handoff")
      }
      const targetId = typeof args.id === "string" ? args.id : selectedTargets.get(sessionKey)
      if (targetId === undefined) throw new Error("There is no selected tab to mark")
      const dispositions = sessionDispositions.get(sessionKey) ?? new Map()
      dispositions.set(targetId, status)
      sessionDispositions.set(sessionKey, dispositions)
      return jsonResult({ id: targetId, status })
    }
    if (toolName === "tabs") {
      const action = stringArgument(args, "action")
      let targets: TargetInfo[] | undefined
      if (action === "new") {
        const url = typeof args.url === "string" ? args.url : "about:blank"
        const created = await active.connection.send<{ targetId: string }>("Target.createTarget", {
          url
        })
        selectedTargets.set(sessionKey, created.targetId)
        const controlled = sessionTargets.get(sessionKey) ?? new Map()
        controlled.set(created.targetId, "created")
        sessionTargets.set(sessionKey, controlled)
        targets = await waitForCreatedTarget(active, created.targetId, url)
      } else {
        targets = await pageTargets(active)
        if (action === "select") {
          const id = typeof args.id === "string" ? args.id : undefined
          const index = id === undefined ? numberArgument(args, "index") : undefined
          const target =
            id === undefined
              ? targets[index!]
              : targets.find((candidate) => candidate.targetId === id)
          if (target === undefined) {
            throw new Error(
              id === undefined ? `No browser tab at index ${index}` : `No browser tab with id ${id}`
            )
          }
          selectedTargets.set(sessionKey, target.targetId)
          const controlled = sessionTargets.get(sessionKey) ?? new Map()
          if (!controlled.has(target.targetId)) controlled.set(target.targetId, "claimed")
          sessionTargets.set(sessionKey, controlled)
        } else if (action === "close") {
          const selectedId = selectedTargets.get(sessionKey)
          const id = typeof args.id === "string" ? args.id : undefined
          const index = typeof args.index === "number" ? args.index : undefined
          const target =
            id !== undefined
              ? targets.find((candidate) => candidate.targetId === id)
              : index === undefined
                ? (targets.find((candidate) => candidate.targetId === selectedId) ?? targets[0])
                : targets[index]
          if (target === undefined) throw new Error("There is no browser tab to close")
          await active.connection.send("Target.closeTarget", { targetId: target.targetId })
          if (selectedId === target.targetId) selectedTargets.delete(sessionKey)
          active.snapshots.delete(target.targetId)
          active.sessions.delete(target.targetId)
          sessionTargets.get(sessionKey)?.delete(target.targetId)
        } else if (action !== "list")
          throw new Error("tabs.action must be list, new, close, or select")
      }
      targets ??= await pageTargets(active)
      const selectedId = selectedTargets.get(sessionKey)
      return jsonResult({
        tabs: targets.map((target, index) => ({
          id: target.targetId,
          index,
          selected: target.targetId === selectedId,
          title: target.title,
          url: target.url
        }))
      })
    }
    if (toolName === "user.history") {
      if (backend !== "extension") {
        throw new Error("Browser history is only available with the user Chrome backend")
      }
      const toTimestamp = (value: unknown): number | undefined => {
        if (typeof value === "number" && Number.isFinite(value)) return value
        if (typeof value !== "string") return undefined
        const parsed = Date.parse(value)
        if (Number.isNaN(parsed)) throw new Error(`Invalid history date: ${value}`)
        return parsed
      }
      const raw = await active.connection.send<{
        entries?: Array<{ url?: string; title?: string; lastVisitTime?: number }>
      }>("Codevisor.getHistory", {
        text:
          Array.isArray(args.queries) && args.queries.every((query) => typeof query === "string")
            ? args.queries.join(" ")
            : "",
        ...(toTimestamp(args.from) === undefined ? {} : { startTime: toTimestamp(args.from) }),
        ...(toTimestamp(args.to) === undefined ? {} : { endTime: toTimestamp(args.to) }),
        maxResults: typeof args.limit === "number" ? Math.max(1, Math.min(1_000, args.limit)) : 100
      })
      return jsonResult({
        entries: (raw.entries ?? [])
          .filter((entry): entry is typeof entry & { url: string } => typeof entry.url === "string")
          .map((entry) => ({
            url: entry.url,
            dateVisited: new Date(entry.lastVisitTime ?? 0).toISOString(),
            ...(typeof entry.title === "string" ? { title: entry.title } : {})
          }))
      })
    }

    const page = await currentPage(active, selectedTargets, sessionKey)
    switch (toolName) {
      case "tab_info": {
        const info = await pageInformation(active, page)
        return jsonResult({ id: page.target.targetId, ...info })
      }
      case "playwright.domSnapshot":
        return snapshotPage(active, page, 60)
      case "playwright.count": {
        const ids = await locatorBackendNodeIds(active, page, args.locator)
        return jsonResult({ count: ids.length })
      }
      case "playwright.allTextContents": {
        const ids = await locatorBackendNodeIds(active, page, args.locator)
        const values: string[] = []
        for (const id of ids) {
          const resolved = await active.connection.send<{ object: { objectId?: string } }>(
            "DOM.resolveNode",
            { backendNodeId: id },
            page.sessionId
          )
          const objectId = resolved.object.objectId
          if (objectId === undefined) continue
          try {
            values.push(
              evaluatedValue<string>(
                await active.connection.send(
                  "Runtime.callFunctionOn",
                  {
                    objectId,
                    functionDeclaration: "function(){return String(this.textContent??'');}",
                    returnByValue: true
                  },
                  page.sessionId
                )
              )
            )
          } finally {
            await active.connection
              .send("Runtime.releaseObject", { objectId }, page.sessionId)
              .catch(() => undefined)
          }
        }
        return jsonResult({ values })
      }
      case "playwright.evaluate": {
        const source = stringArgument(args, "function")
        return jsonResult({
          value:
            args.locator === undefined
              ? await evaluateReadOnly(active, page, source, args.arg)
              : await evaluateLocatorReadOnly(active, page, args.locator, source, args.arg)
        })
      }
      case "playwright.downloadMedia": {
        const element = await resolveLocatorElement(
          active,
          page,
          args.locator,
          false,
          Number(args.timeoutMs ?? 30_000)
        )
        try {
          await triggerMediaDownload(active, page, element.objectId)
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "playwright.downloadMedia")
      }
      case "playwright.waitForEvent": {
        const event = stringArgument(args, "event")
        const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
        if (event === "filechooser") {
          await active.connection.send(
            "Page.setInterceptFileChooserDialog",
            { enabled: true },
            page.sessionId
          )
          const opened = await waitForCdpEvent(
            active,
            "Page.fileChooserOpened",
            page.sessionId,
            timeoutMs
          )
          const backendNodeId = Number(opened.backendNodeId)
          if (!Number.isInteger(backendNodeId)) {
            throw new Error("The file chooser did not identify its file input")
          }
          const chooserId = randomUUID()
          active.fileChoosers.set(chooserId, { sessionId: page.sessionId, backendNodeId })
          return jsonResult({
            event,
            chooserId,
            multiple: opened.mode === "selectMultiple"
          })
        }
        if (event === "download") {
          const eventSessionId = backend === "extension" ? page.sessionId : undefined
          const eventPromise = waitForCdpEvent(
            active,
            "Browser.downloadWillBegin",
            eventSessionId,
            timeoutMs
          )
          if (backend === "extension") {
            await active.connection.send("Codevisor.armDownload", { timeoutMs }, page.sessionId)
          } else {
            await active.connection.send("Browser.setDownloadBehavior", {
              behavior: "allowAndName",
              downloadPath: downloadsDir,
              eventsEnabled: true
            })
          }
          const download = await eventPromise
          const guid = String(download.guid ?? randomUUID())
          const existing = active.downloads.get(guid)
          const value = {
            guid,
            url: String(download.url ?? ""),
            suggestedFilename: String(download.suggestedFilename ?? "download"),
            ...(typeof download.filePath === "string" ? { path: download.filePath } : {}),
            ...existing
          }
          active.downloads.set(guid, value)
          return jsonResult({ event, downloadId: guid, ...value })
        }
        throw new Error("event must be filechooser or download")
      }
      case "playwright.fileChooserSetFiles": {
        if (!Array.isArray(args.paths) || !args.paths.every((value) => typeof value === "string")) {
          throw new Error("paths must be an array of workspace file paths")
        }
        const chooserId = stringArgument(args, "chooserId")
        const chooser = active.fileChoosers.get(chooserId)
        if (chooser === undefined) throw new Error("Unknown or expired file chooser")
        await active.connection.send(
          "DOM.setFileInputFiles",
          { files: args.paths, backendNodeId: chooser.backendNodeId },
          chooser.sessionId
        )
        active.fileChoosers.delete(chooserId)
        await active.connection
          .send("Page.setInterceptFileChooserDialog", { enabled: false }, chooser.sessionId)
          .catch(() => undefined)
        return jsonResult({ fileCount: args.paths.length })
      }
      case "playwright.downloadPath": {
        const downloadId = stringArgument(args, "downloadId")
        const deadline =
          Date.now() + Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
        while (true) {
          const download = active.downloads.get(downloadId)
          if (download?.state === "canceled") throw new Error("Download was canceled")
          if (download?.state === "completed") {
            return jsonResult({ path: download.path ?? join(downloadsDir, downloadId) })
          }
          if (Date.now() >= deadline) throw new Error("Timed out waiting for download")
          await delay(100)
        }
      }
      case "playwright.click": {
        const element = await resolveLocatorElement(
          active,
          page,
          args.locator,
          args.force !== true,
          Number(args.timeoutMs ?? 30_000)
        )
        try {
          await dispatchClick(
            active,
            page,
            element.x,
            element.y,
            String(args.button ?? "left"),
            args.doubleClick === true ? 2 : 1,
            mouseModifierMask(args.modifiers)
          )
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "playwright.click", { addressing: "locator" })
      }
      case "playwright.fill": {
        const value = stringArgument(args, "value")
        const element = await resolveLocatorElement(
          active,
          page,
          args.locator,
          true,
          Number(args.timeoutMs ?? 30_000)
        )
        let actual: string | undefined
        try {
          actual = await fillResolvedElement(active, page, element, value, false, true)
        } finally {
          await releaseElement(active, page, element)
        }
        return verifiedActionResult(active, page, "playwright.fill", { value: actual })
      }
      case "playwright.type": {
        const value = stringArgument(args, "value")
        const element = await resolveLocatorElement(
          active,
          page,
          args.locator,
          true,
          Number(args.timeoutMs ?? 30_000)
        )
        try {
          await fillResolvedElement(active, page, element, value, false, false)
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "playwright.type")
      }
      case "playwright.press": {
        const element = await resolveLocatorElement(
          active,
          page,
          args.locator,
          true,
          Number(args.timeoutMs ?? 30_000)
        )
        try {
          await active.connection.send(
            "Runtime.callFunctionOn",
            {
              objectId: element.objectId,
              functionDeclaration: "function(){this.focus();}",
              returnByValue: true
            },
            page.sessionId
          )
          await pressKey(active, page, stringArgument(args, "key"))
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "playwright.press", { key: args.key })
      }
      case "playwright.check":
      case "playwright.uncheck":
      case "playwright.setChecked": {
        const desired =
          toolName === "playwright.check"
            ? true
            : toolName === "playwright.uncheck"
              ? false
              : booleanArgument(args, "checked")
        const element = await resolveLocatorElement(
          active,
          page,
          args.locator,
          args.force !== true,
          Number(args.timeoutMs ?? 30_000)
        )
        try {
          await setCheckedElement(active, page, element, desired)
        } finally {
          await releaseElement(active, page, element)
        }
        return verifiedActionResult(active, page, toolName, { checked: desired })
      }
      case "playwright.selectOption": {
        if (!Array.isArray(args.values)) throw new Error("values must be an array")
        const element = await resolveLocatorElement(
          active,
          page,
          args.locator,
          true,
          Number(args.timeoutMs ?? 30_000)
        )
        let selected: string[]
        try {
          selected = await selectOptionsElement(active, page, element, args.values)
        } finally {
          await releaseElement(active, page, element)
        }
        return jsonResult({ selected, verified: true })
      }
      case "playwright.isVisible":
        return jsonResult({ visible: await locatorIsVisible(active, page, args.locator) })
      case "playwright.isEnabled":
        return jsonResult({
          enabled: await callLocatorFunction<boolean>(
            active,
            page,
            args.locator,
            "function(){return !this.disabled&&this.getAttribute('aria-disabled')!=='true';}",
            [],
            Number(args.timeoutMs ?? 30_000)
          )
        })
      case "playwright.getAttribute":
        return jsonResult({
          value: await callLocatorFunction<string | null>(
            active,
            page,
            args.locator,
            "function(name){return this.getAttribute(name);}",
            [stringArgument(args, "name")],
            Number(args.timeoutMs ?? 30_000)
          )
        })
      case "playwright.innerText":
        return jsonResult({
          value: await callLocatorFunction<string>(
            active,
            page,
            args.locator,
            "function(){return String(this.innerText||'');}",
            [],
            Number(args.timeoutMs ?? 30_000)
          )
        })
      case "playwright.textContent":
        return jsonResult({
          value: await callLocatorFunction<string | null>(
            active,
            page,
            args.locator,
            "function(){return this.textContent; }",
            [],
            Number(args.timeoutMs ?? 30_000)
          )
        })
      case "playwright.waitFor": {
        const state = stringArgument(args, "state")
        if (!["attached", "detached", "visible", "hidden"].includes(state)) {
          throw new Error("state must be attached, detached, visible, or hidden")
        }
        const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
        const deadline = Date.now() + timeoutMs
        while (true) {
          const ids = await locatorBackendNodeIds(active, page, args.locator)
          const satisfied =
            state === "attached"
              ? ids.length > 0
              : state === "detached"
                ? ids.length === 0
                : state === "visible"
                  ? ids.length === 1 && (await locatorIsVisible(active, page, args.locator))
                  : ids.length === 0 ||
                    (ids.length === 1 && !(await locatorIsVisible(active, page, args.locator)))
          if (satisfied) return jsonResult({ state, matched: true })
          if (ids.length > 1) {
            throw new Error(
              `Playwright strict mode violation: locator resolved to ${ids.length} elements`
            )
          }
          if (Date.now() >= deadline) {
            throw new Error(`Timed out waiting for locator to become ${state}`)
          }
          await delay(100)
        }
      }
      case "playwright.waitForTimeout":
        await delay(Math.max(0, Math.min(30_000, numberArgument(args, "timeoutMs"))))
        return jsonResult({ waited: true })
      case "playwright.waitForURL": {
        const expected = stringArgument(args, "url")
        const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
        const waitUntil = typeof args.waitUntil === "string" ? args.waitUntil : "commit"
        const deadline = Date.now() + timeoutMs
        while (true) {
          const info = await pageInformation(active, page)
          if (info.url === expected) {
            if (waitUntil === "domcontentloaded") await waitForReady(active, page)
            if (waitUntil === "load" || waitUntil === "networkidle") {
              while ((await evaluate<string>(active, page, "document.readyState")) !== "complete") {
                if (Date.now() >= deadline) {
                  throw new Error(`Timed out waiting for URL ${expected}`)
                }
                await delay(100)
              }
              if (waitUntil === "networkidle") await delay(500)
            }
            return jsonResult({ url: info.url, matched: true })
          }
          if (Date.now() >= deadline) throw new Error(`Timed out waiting for URL ${expected}`)
          await delay(100)
        }
      }
      case "playwright.waitForLoadState": {
        const state = typeof args.state === "string" ? args.state : "load"
        if (!["domcontentloaded", "load", "networkidle"].includes(state)) {
          throw new Error("state must be domcontentloaded, load, or networkidle")
        }
        const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
        const deadline = Date.now() + timeoutMs
        while (true) {
          const readyState = await evaluate<string>(active, page, "document.readyState")
          const ready =
            state === "domcontentloaded"
              ? readyState === "interactive" || readyState === "complete"
              : readyState === "complete"
          if (ready) {
            if (state === "networkidle") await delay(500)
            return jsonResult({ state, matched: true })
          }
          if (Date.now() >= deadline) {
            throw new Error(`Timed out waiting for load state ${state}`)
          }
          await delay(100)
        }
      }
      case "clipboard.readText": {
        if (backend === "extension") {
          const value = await active.connection.send<{ text?: string }>(
            "Codevisor.clipboard.readText"
          )
          return jsonResult({ text: String(value.text ?? "") })
        }
        await grantClipboardPermissions(active, page)
        const value = await evaluateReadOnly<string>(
          active,
          page,
          "async () => await navigator.clipboard.readText()",
          undefined
        )
        return jsonResult({ text: value })
      }
      case "clipboard.writeText": {
        const text = stringArgument(args, "text")
        if (backend === "extension") {
          await active.connection.send("Codevisor.clipboard.writeText", { text })
          return jsonResult({ written: true })
        }
        await grantClipboardPermissions(active, page)
        await active.connection.send(
          "Runtime.evaluate",
          {
            expression: `navigator.clipboard.writeText(${JSON.stringify(text)})`,
            awaitPromise: true,
            userGesture: true,
            returnByValue: true
          },
          page.sessionId
        )
        return jsonResult({ written: true })
      }
      case "clipboard.read": {
        if (backend === "extension") {
          const value = await active.connection.send<{ items?: unknown[] }>(
            "Codevisor.clipboard.read"
          )
          return jsonResult({ items: value.items ?? [] })
        }
        await grantClipboardPermissions(active, page)
        const rawItems = await evaluateReadOnly<
          Array<{ readonly types: string[]; readonly data: Readonly<Record<string, string>> }>
        >(
          active,
          page,
          "async () => Promise.all((await navigator.clipboard.read()).map(async item => ({types:[...item.types],data:Object.fromEntries(await Promise.all(item.types.map(async type=>{const bytes=new Uint8Array(await (await item.getType(type)).arrayBuffer());let binary='';for(let index=0;index<bytes.length;index+=0x8000)binary+=String.fromCharCode(...bytes.subarray(index,index+0x8000));return [type,btoa(binary)];})))})))",
          undefined
        )
        return jsonResult({
          items: rawItems.map((item) => ({
            entries: item.types.map((mimeType) => {
              const base64 = item.data[mimeType] ?? ""
              return mimeType.startsWith("text/")
                ? { mimeType, text: Buffer.from(base64, "base64").toString("utf8") }
                : { mimeType, base64 }
            })
          }))
        })
      }
      case "clipboard.write": {
        if (!Array.isArray(args.items)) throw new Error("items must be an array")
        if (backend === "extension") {
          await active.connection.send("Codevisor.clipboard.write", { items: args.items })
          return jsonResult({ written: true })
        }
        await grantClipboardPermissions(active, page)
        await active.connection.send(
          "Runtime.evaluate",
          {
            expression: `(async(items)=>navigator.clipboard.write(items.map(item=>new ClipboardItem(Object.fromEntries((item.entries??[]).map(entry=>{if(typeof entry.text==='string')return[entry.mimeType,new Blob([entry.text],{type:entry.mimeType})];const binary=atob(entry.base64??''),bytes=Uint8Array.from(binary,char=>char.charCodeAt(0));return[entry.mimeType,new Blob([bytes],{type:entry.mimeType})]})),{presentationStyle:item.presentationStyle}))))(${JSON.stringify(args.items)})`,
            awaitPromise: true,
            userGesture: true,
            returnByValue: true
          },
          page.sessionId
        )
        return jsonResult({ written: true })
      }
      case "dev.logs": {
        const levels =
          Array.isArray(args.levels) && args.levels.every((level) => typeof level === "string")
            ? new Set(args.levels.map((level) => (level === "warning" ? "warn" : level)))
            : undefined
        const filter = typeof args.filter === "string" ? args.filter : undefined
        const normalized = (active.logs.get(page.sessionId) ?? []).map((entry) => {
          if (entry.method === "Runtime.consoleAPICalled") {
            const args = Array.isArray(entry.args)
              ? (entry.args as Array<Readonly<Record<string, unknown>>>)
              : []
            const message = args
              .map((value) => String(value.value ?? value.description ?? value.type ?? ""))
              .join(" ")
            return {
              level: entry.type === "warning" ? "warn" : String(entry.type ?? "log"),
              message,
              timestamp: new Date(Number(entry.timestamp ?? Date.now())).toISOString()
            }
          }
          if (entry.method === "Log.entryAdded") {
            const value =
              entry.entry !== null && typeof entry.entry === "object"
                ? (entry.entry as Readonly<Record<string, unknown>>)
                : {}
            return {
              level: value.level === "warning" ? "warn" : String(value.level ?? "log"),
              message: String(value.text ?? ""),
              timestamp: new Date(Number(value.timestamp ?? Date.now())).toISOString(),
              ...(typeof value.url === "string" ? { url: value.url } : {})
            }
          }
          const detail =
            entry.exceptionDetails !== null && typeof entry.exceptionDetails === "object"
              ? (entry.exceptionDetails as Readonly<Record<string, unknown>>)
              : {}
          const exception =
            detail.exception !== null && typeof detail.exception === "object"
              ? (detail.exception as Readonly<Record<string, unknown>>)
              : {}
          return {
            level: "error",
            message: String(exception.description ?? detail.text ?? "Uncaught page error"),
            timestamp: new Date(Number(entry.timestamp ?? Date.now())).toISOString(),
            ...(typeof detail.url === "string" ? { url: detail.url } : {})
          }
        })
        const entries = normalized
          .filter(
            (entry) =>
              (levels === undefined || levels.has(entry.level)) &&
              (filter === undefined || entry.message.includes(filter))
          )
          .slice(-Math.max(1, Math.min(1_000, Number(args.limit ?? 100))))
        return jsonResult({ entries })
      }
      case "getJsDialog":
        return jsonResult({ dialog: active.dialogs.get(page.sessionId) ?? null })
      case "viewport.set": {
        const width = Math.round(numberArgument(args, "width"))
        const height = Math.round(numberArgument(args, "height"))
        await active.connection.send(
          "Emulation.setDeviceMetricsOverride",
          { width, height, deviceScaleFactor: 1, mobile: false },
          page.sessionId
        )
        return jsonResult({ width, height })
      }
      case "viewport.reset":
        await active.connection.send("Emulation.clearDeviceMetricsOverride", {}, page.sessionId)
        return jsonResult({ reset: true })
      case "cdp.send": {
        const method = stringArgument(args, "method")
        const target =
          args.target !== null && typeof args.target === "object"
            ? (args.target as Readonly<Record<string, unknown>>)
            : undefined
        let sessionId = page.sessionId
        if (typeof target?.sessionId === "string") sessionId = target.sessionId
        if (typeof target?.targetId === "string") {
          sessionId = await attachTarget(active, target.targetId)
        }
        const params =
          args.params !== null && typeof args.params === "object" && !Array.isArray(args.params)
            ? (args.params as Readonly<Record<string, unknown>>)
            : {}
        const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 30_000)))
        return jsonResult({
          result: await active.connection.send(method, params, sessionId, timeoutMs)
        })
      }
      case "cdp.readEvents": {
        const afterSequence =
          typeof args.afterSequence === "number"
            ? Math.max(0, args.afterSequence)
            : active.eventSequence
        const limit = Math.max(1, Math.min(1_000, Number(args.limit ?? 100)))
        const methods =
          Array.isArray(args.methods) && args.methods.every((method) => typeof method === "string")
            ? new Set(args.methods)
            : undefined
        const target =
          args.target !== null && typeof args.target === "object"
            ? (args.target as Readonly<Record<string, unknown>>)
            : undefined
        const targetSession =
          typeof target?.sessionId === "string"
            ? target.sessionId
            : typeof target?.targetId === "string"
              ? active.sessions.get(target.targetId)
              : page.sessionId
        const matches = () =>
          active.eventLog.filter(
            (event) =>
              event.sequence > afterSequence &&
              (methods === undefined || methods.has(event.method)) &&
              (targetSession === undefined || event.sessionId === targetSession)
          )
        const timeoutMs = Math.max(0, Math.min(30_000, Number(args.timeoutMs ?? 0)))
        const deadline = Date.now() + timeoutMs
        while (matches().length === 0 && Date.now() < deadline) await delay(50)
        const all = matches()
        const events = all.slice(0, limit).map((event) => ({
          method: event.method,
          params: event.params,
          sequence: event.sequence,
          source: {
            ...(event.sessionId === undefined ? {} : { sessionId: event.sessionId }),
            targetId:
              [...active.sessions.entries()].find(
                ([, sessionId]) => sessionId === event.sessionId
              )?.[0] ?? page.target.targetId
          }
        }))
        return jsonResult({
          cursor: events.at(-1)?.sequence ?? active.eventSequence,
          events,
          hasMore: all.length > events.length,
          truncated: active.eventLog.length > 0 && afterSequence < active.eventLog[0]!.sequence - 1
        })
      }
      case "pageAssets.list": {
        const inventory = await evaluate<{
          pageUrl: string
          assets: Array<{ url: string; kind: string }>
          inlineSvgs: Array<{ markup: string }>
        }>(
          active,
          page,
          `(()=>{const urls=new Map();const classify=kind=>kind==='img'?'image':kind==='css'||kind==='link'?'stylesheet':kind==='video'||kind==='media'||kind==='audio'||kind==='source'?'video':kind==='script'?'script':kind==='font'?'font':'other';const add=(url,kind)=>{try{const absolute=new URL(url,location.href).href;if(!urls.has(absolute))urls.set(absolute,{url:absolute,kind:classify(kind)});}catch{}};for(const entry of performance.getEntriesByType('resource'))add(entry.name,entry.initiatorType||'other');for(const element of document.querySelectorAll('img[src],video[src],audio[src],source[src],script[src],link[href]'))add(element.src||element.href,element.tagName.toLowerCase());return{pageUrl:location.href,assets:[...urls.values()],inlineSvgs:[...document.querySelectorAll('svg')].map(svg=>({markup:svg.outerHTML}))};})()`
        )
        const id = randomUUID()
        const normalized = {
          pageUrl: inventory.pageUrl,
          assets: inventory.assets.map((asset, index) => ({
            id: `a${index + 1}`,
            ...asset,
            name: (() => {
              try {
                return basename(new URL(asset.url).pathname) || `asset-${index + 1}`
              } catch {
                return `asset-${index + 1}`
              }
            })(),
            sources: [{ kind: "resource" }]
          })),
          inlineSvgs: inventory.inlineSvgs.map((asset, index) => ({
            id: `s${index + 1}`,
            ...asset,
            name: `inline-${index + 1}.svg`
          }))
        }
        assetInventories.set(id, normalized)
        const byKind = Object.fromEntries(
          [...new Set(normalized.assets.map((asset) => asset.kind))].map((kind) => [
            kind,
            normalized.assets.filter((asset) => asset.kind === kind).length
          ])
        )
        return jsonResult({
          id,
          ...normalized,
          summary: {
            byKind,
            inlineSvgCount: normalized.inlineSvgs.length,
            totalCount: normalized.assets.length + normalized.inlineSvgs.length
          }
        })
      }
      case "pageAssets.bundle": {
        const inventoryId = stringArgument(args, "inventoryId")
        const inventory = assetInventories.get(inventoryId)
        if (inventory === undefined) throw new Error("Unknown or expired page asset inventory")
        const selectedIds =
          Array.isArray(args.assetIds) &&
          args.assetIds.every((assetId) => typeof assetId === "string")
            ? new Set(args.assetIds)
            : undefined
        const kinds =
          Array.isArray(args.kinds) && args.kinds.every((kind) => typeof kind === "string")
            ? new Set(args.kinds)
            : undefined
        const bundleDir = join(assetsDir, inventoryId)
        mkdirSync(bundleDir, { recursive: true, mode: 0o700 })
        const saved: Array<{
          contentType: string | null
          id: string
          kind: string
          name: string
          path: string
          url: string
        }> = []
        const failures: Array<{
          contentType: string | null
          id: string
          name: string
          reason: string
          url: string
        }> = []
        const requested = inventory.assets.filter(
          (asset) =>
            (selectedIds === undefined || selectedIds.has(asset.id)) &&
            (kinds === undefined || kinds.has(asset.kind))
        )
        const startedAt = Date.now()
        for (const asset of inventory.assets) {
          if (selectedIds !== undefined && !selectedIds.has(asset.id)) continue
          if (kinds !== undefined && !kinds.has(asset.kind)) continue
          const fetched = await evaluate<{ base64?: string; mimeType?: string; error?: string }>(
            active,
            page,
            `(async()=>{try{const response=await fetch(${JSON.stringify(asset.url)});if(!response.ok)return{error:String(response.status)};const bytes=new Uint8Array(await response.arrayBuffer());let binary='';for(let index=0;index<bytes.length;index+=0x8000)binary+=String.fromCharCode(...bytes.subarray(index,index+0x8000));return{base64:btoa(binary),mimeType:response.headers.get('content-type')||undefined};}catch(error){return{error:String(error)}}})()`
          )
          if (fetched.base64 === undefined) {
            failures.push({
              contentType: fetched.mimeType ?? null,
              id: asset.id,
              name: asset.name,
              reason: fetched.error ?? "Download failed",
              url: asset.url
            })
            continue
          }
          const path = join(
            bundleDir,
            `${asset.id}-${asset.name.replaceAll(/[^a-zA-Z0-9._-]/g, "_")}`
          )
          writeFileSync(path, Buffer.from(fetched.base64, "base64"), { mode: 0o600 })
          saved.push({
            contentType: fetched.mimeType ?? null,
            id: asset.id,
            kind: asset.kind,
            name: asset.name,
            path,
            url: asset.url
          })
        }
        const manifestPath = join(bundleDir, "manifest.json")
        writeFileSync(
          manifestPath,
          JSON.stringify(
            { inventoryId, pageUrl: inventory.pageUrl, assets: saved, failures },
            null,
            2
          ),
          { mode: 0o600 }
        )
        return jsonResult({
          assets: saved,
          directoryPath: bundleDir,
          failures,
          manifestPath,
          summary: {
            downloadedCount: saved.length,
            elapsedMs: Date.now() - startedAt,
            failedCount: failures.length,
            requestedCount: requested.length
          }
        })
      }
      case "navigate": {
        const url = stringArgument(args, "url")
        const response = await active.connection.send<{ errorText?: string }>(
          "Page.navigate",
          { url },
          page.sessionId
        )
        if (response.errorText !== undefined) throw new Error(response.errorText)
        await waitForReady(active, page)
        return pageResult(active, page, { action: "navigate", path: "cdp", delivered: true })
      }
      case "back":
      case "forward": {
        const history = await active.connection.send<{
          currentIndex: number
          entries: Array<{ id: number }>
        }>("Page.getNavigationHistory", {}, page.sessionId)
        const offset = toolName === "back" ? -1 : 1
        const entry = history.entries[history.currentIndex + offset]
        if (entry === undefined) throw new Error(`There is no page to navigate ${toolName}`)
        await active.connection.send(
          "Page.navigateToHistoryEntry",
          { entryId: entry.id },
          page.sessionId
        )
        await waitForReady(active, page)
        return pageResult(active, page, { action: toolName, path: "cdp", delivered: true })
      }
      case "reload":
        await active.connection.send("Page.reload", {}, page.sessionId)
        await waitForReady(active, page)
        return pageResult(active, page, { action: "reload", path: "cdp", delivered: true })
      case "snapshot":
        return snapshotPage(active, page, Math.max(1, Math.min(60, Number(args.depth ?? 30))))
      case "screenshot": {
        const format = args.type === "jpeg" ? "jpeg" : "png"
        let clip: { x: number; y: number; width: number; height: number; scale: number } | undefined
        let element: ResolvedElement | undefined
        if (args.clip !== undefined) {
          if (args.clip === null || typeof args.clip !== "object" || Array.isArray(args.clip)) {
            throw new Error("clip must be an object")
          }
          const requested = args.clip as Readonly<Record<string, unknown>>
          clip = {
            x: numberArgument(requested, "x"),
            y: numberArgument(requested, "y"),
            width: numberArgument(requested, "width"),
            height: numberArgument(requested, "height"),
            scale: 1
          }
        } else if (args.target !== undefined) {
          element = await resolveElement(active, page, args.target, false)
          const metrics = await active.connection.send<{
            cssVisualViewport: { pageX: number; pageY: number }
          }>("Page.getLayoutMetrics", {}, page.sessionId)
          clip = {
            x: metrics.cssVisualViewport.pageX + element.x - element.width / 2,
            y: metrics.cssVisualViewport.pageY + element.y - element.height / 2,
            width: element.width,
            height: element.height,
            scale: 1
          }
        } else if (args.fullPage === true) {
          const metrics = await active.connection.send<{
            contentSize: { x: number; y: number; width: number; height: number }
          }>("Page.getLayoutMetrics", {}, page.sessionId)
          clip = { ...metrics.contentSize, scale: 1 }
        } else {
          const metrics = await active.connection.send<{
            cssVisualViewport: {
              pageX: number
              pageY: number
              clientWidth: number
              clientHeight: number
            }
          }>("Page.getLayoutMetrics", {}, page.sessionId)
          clip = {
            x: metrics.cssVisualViewport.pageX,
            y: metrics.cssVisualViewport.pageY,
            width: metrics.cssVisualViewport.clientWidth,
            height: metrics.cssVisualViewport.clientHeight,
            scale: 1
          }
        }
        try {
          const captured = await active.connection.send<{ data: string }>(
            "Page.captureScreenshot",
            {
              format,
              fromSurface: true,
              captureBeyondViewport: args.fullPage === true,
              clip
            },
            page.sessionId
          )
          const info = await pageInformation(active, page)
          return {
            content: [
              {
                type: "text",
                text: `Page URL: ${info.url}\nScreenshot coordinates are CSS viewport coordinates.`
              },
              { type: "image", data: captured.data, mimeType: `image/${format}` }
            ]
          }
        } finally {
          if (element !== undefined) await releaseElement(active, page, element)
        }
      }
      case "click": {
        const element = await resolveElement(active, page, args.target)
        try {
          await dispatchClick(
            active,
            page,
            element.x,
            element.y,
            String(args.button ?? "left"),
            args.doubleClick === true ? 2 : 1
          )
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "click", {
          addressing: "element",
          target: normalizeRef(args.target)
        })
      }
      case "hover": {
        const element = await resolveElement(active, page, args.target, false)
        try {
          await active.connection.send(
            "Input.dispatchMouseEvent",
            { type: "mouseMoved", x: element.x, y: element.y },
            page.sessionId
          )
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "hover", { target: normalizeRef(args.target) })
      }
      case "drag": {
        const start = await resolveElement(active, page, args.startTarget)
        const end = await resolveElement(active, page, args.endTarget)
        try {
          await active.connection.send(
            "Input.dispatchMouseEvent",
            { type: "mouseMoved", x: start.x, y: start.y },
            page.sessionId
          )
          await active.connection.send(
            "Input.dispatchMouseEvent",
            {
              type: "mousePressed",
              x: start.x,
              y: start.y,
              button: "left",
              buttons: 1,
              clickCount: 1
            },
            page.sessionId
          )
          for (let step = 1; step <= 10; step++) {
            const progress = step / 10
            await active.connection.send(
              "Input.dispatchMouseEvent",
              {
                type: "mouseMoved",
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress,
                button: "left",
                buttons: 1
              },
              page.sessionId
            )
            await delay(16)
          }
          await active.connection.send(
            "Input.dispatchMouseEvent",
            {
              type: "mouseReleased",
              x: end.x,
              y: end.y,
              button: "left",
              buttons: 0,
              clickCount: 1
            },
            page.sessionId
          )
        } finally {
          await Promise.all([
            releaseElement(active, page, start),
            releaseElement(active, page, end)
          ])
        }
        return actionResult(active, page, "drag", { addressing: "elements" })
      }
      case "type":
        await fillElement(
          active,
          page,
          args.target,
          stringArgument(args, "text"),
          args.slowly === true
        )
        if (args.submit === true) await pressKey(active, page, "Enter")
        return actionResult(active, page, "type", { target: normalizeRef(args.target) })
      case "fill_form": {
        if (!Array.isArray(args.fields)) throw new Error("fields must be an array")
        for (const field of args.fields) {
          if (field === null || typeof field !== "object")
            throw new Error("Each field must be an object")
          const entry = field as Readonly<Record<string, unknown>>
          const target = entry.target ?? entry.ref
          const value = entry.value
          if (
            typeof value !== "string" &&
            typeof value !== "number" &&
            typeof value !== "boolean"
          ) {
            throw new Error("Each field value must be a string, number, or boolean")
          }
          await fillElement(active, page, target, String(value), false)
        }
        return verifiedActionResult(active, page, "fill_form", {
          fieldCount: args.fields.length
        })
      }
      case "select_option": {
        if (
          !Array.isArray(args.values) ||
          !args.values.every((value) => typeof value === "string")
        ) {
          throw new Error("values must be an array of strings")
        }
        const element = await resolveElement(active, page, args.target)
        let selected: string[]
        try {
          selected = await selectOptionsElement(active, page, element, args.values)
        } finally {
          await releaseElement(active, page, element)
        }
        return verifiedActionResult(active, page, "select_option", {
          target: normalizeRef(args.target),
          selected
        })
      }
      case "press_key":
        await pressKey(active, page, stringArgument(args, "key"))
        return actionResult(active, page, "press_key", { key: args.key })
      case "keyboard_type":
        await active.connection.send(
          "Input.insertText",
          { text: stringArgument(args, "text") },
          page.sessionId
        )
        return actionResult(active, page, "keyboard_type")
      case "wait": {
        if (typeof args.time === "number") await delay(Math.max(0, Math.min(30, args.time)) * 1_000)
        const expected = typeof args.text === "string" ? args.text : undefined
        const gone = typeof args.textGone === "string" ? args.textGone : undefined
        if (expected !== undefined || gone !== undefined) {
          const deadline = Date.now() + 30_000
          while (true) {
            const body = await evaluate<string>(active, page, "document.body?.innerText ?? ''")
            if (
              (expected === undefined || body.includes(expected)) &&
              (gone === undefined || !body.includes(gone))
            )
              break
            if (Date.now() >= deadline) throw new Error("Timed out waiting for page text")
            await delay(200)
          }
        }
        return pageResult(active, page, { action: "wait", path: "cdp", conditionMet: true })
      }
      case "dialog":
        await active.connection.send(
          "Page.handleJavaScriptDialog",
          {
            accept: args.accept === true,
            ...(typeof args.promptText === "string" ? { promptText: args.promptText } : {})
          },
          page.sessionId
        )
        return actionResult(active, page, "dialog")
      case "upload_files": {
        if (!Array.isArray(args.paths) || !args.paths.every((value) => typeof value === "string")) {
          throw new Error("paths must be an array of workspace file paths")
        }
        const snapshot = active.snapshots.get(page.target.targetId)
        const backendNodeId = snapshot?.targets.get(normalizeRef(args.target))
        if (backendNodeId === undefined)
          throw new Error("Unknown or stale file input target; re-snapshot")
        await active.connection.send(
          "DOM.setFileInputFiles",
          { files: args.paths, backendNodeId },
          page.sessionId
        )
        return actionResult(active, page, "upload_files", { fileCount: args.paths.length })
      }
      case "mouse_click": {
        const x = numberArgument(args, "x")
        const y = numberArgument(args, "y")
        await dispatchClick(
          active,
          page,
          x,
          y,
          String(args.button ?? "left"),
          args.doubleClick === true ? 2 : 1,
          mouseModifierMask(args.keypress)
        )
        return actionResult(active, page, "mouse_click", {
          addressing: "coordinate",
          x,
          y,
          doubleClick: args.doubleClick === true
        })
      }
      case "mouse_move": {
        const x = numberArgument(args, "x")
        const y = numberArgument(args, "y")
        await active.connection.send(
          "Input.dispatchMouseEvent",
          { type: "mouseMoved", x, y, modifiers: mouseModifierMask(args.keys) },
          page.sessionId
        )
        return actionResult(active, page, "mouse_move", { x, y })
      }
      case "mouse_drag": {
        const path = Array.isArray(args.path)
          ? args.path.map((point) => {
              if (point === null || typeof point !== "object" || Array.isArray(point)) {
                throw new Error("Each drag path point must be an object")
              }
              const candidate = point as Readonly<Record<string, unknown>>
              return { x: numberArgument(candidate, "x"), y: numberArgument(candidate, "y") }
            })
          : [
              { x: numberArgument(args, "startX"), y: numberArgument(args, "startY") },
              { x: numberArgument(args, "endX"), y: numberArgument(args, "endY") }
            ]
        if (path.length < 2) throw new Error("mouse_drag path must contain at least two points")
        const start = path[0]!
        const end = path.at(-1)!
        await active.connection.send(
          "Input.dispatchMouseEvent",
          {
            type: "mouseMoved",
            x: start.x,
            y: start.y,
            modifiers: mouseModifierMask(args.keys)
          },
          page.sessionId
        )
        await active.connection.send(
          "Input.dispatchMouseEvent",
          {
            type: "mousePressed",
            x: start.x,
            y: start.y,
            button: "left",
            buttons: 1,
            clickCount: 1,
            modifiers: mouseModifierMask(args.keys)
          },
          page.sessionId
        )
        for (const point of path.slice(1)) {
          await active.connection.send(
            "Input.dispatchMouseEvent",
            {
              type: "mouseMoved",
              x: point.x,
              y: point.y,
              button: "left",
              buttons: 1,
              modifiers: mouseModifierMask(args.keys)
            },
            page.sessionId
          )
        }
        await active.connection.send(
          "Input.dispatchMouseEvent",
          {
            type: "mouseReleased",
            x: end.x,
            y: end.y,
            button: "left",
            buttons: 0,
            clickCount: 1,
            modifiers: mouseModifierMask(args.keys)
          },
          page.sessionId
        )
        return actionResult(active, page, "mouse_drag", { pathLength: path.length })
      }
      case "mouse_scroll":
        await active.connection.send(
          "Input.dispatchMouseEvent",
          {
            type: "mouseWheel",
            x: typeof args.x === "number" ? args.x : 0,
            y: typeof args.y === "number" ? args.y : 0,
            deltaX: typeof args.deltaX === "number" ? args.deltaX : 0,
            deltaY: numberArgument(args, "deltaY"),
            modifiers: mouseModifierMask(args.keypress)
          },
          page.sessionId
        )
        return actionResult(active, page, "mouse_scroll")
      case "mouse_download_media": {
        const objectId = await mediaElementAtPoint(
          active,
          page,
          numberArgument(args, "x"),
          numberArgument(args, "y")
        )
        try {
          await triggerMediaDownload(active, page, objectId)
        } finally {
          await active.connection
            .send("Runtime.releaseObject", { objectId }, page.sessionId)
            .catch(() => undefined)
        }
        return actionResult(active, page, "mouse_download_media")
      }
      case "dom_download_media": {
        const element = await resolveElement(active, page, args.target, false)
        try {
          await triggerMediaDownload(active, page, element.objectId)
        } finally {
          await releaseElement(active, page, element)
        }
        return actionResult(active, page, "dom_download_media")
      }
      case "dom_scroll": {
        if (typeof args.target === "string") {
          const element = await resolveElement(active, page, args.target, false)
          try {
            await active.connection.send(
              "Runtime.callFunctionOn",
              {
                objectId: element.objectId,
                functionDeclaration: "function(x,y){this.scrollBy(x,y);}",
                arguments: [
                  { value: numberArgument(args, "x") },
                  { value: numberArgument(args, "y") }
                ],
                returnByValue: true
              },
              page.sessionId
            )
          } finally {
            await releaseElement(active, page, element)
          }
        } else {
          await active.connection.send(
            "Input.dispatchMouseEvent",
            {
              type: "mouseWheel",
              x: 0,
              y: 0,
              deltaX: numberArgument(args, "x"),
              deltaY: numberArgument(args, "y")
            },
            page.sessionId
          )
        }
        return actionResult(active, page, "dom_scroll")
      }
      default:
        throw new Error(`Unknown Browser Use tool: ${toolName}`)
    }
  }

  const closeRuntime = async (active: BrowserRuntime): Promise<void> => {
    await active.queue.catch(() => undefined)
    for (const dispose of active.eventDisposers.splice(0)) dispose()
    if (active.owned) {
      await active.connection.send("Browser.close").catch(() => undefined)
      if (active.processHandle !== undefined && active.processHandle.exitCode === null) {
        await Promise.race([
          new Promise<void>((resolve) => active.processHandle!.once("exit", () => resolve())),
          delay(500)
        ])
      }
      if (active.processHandle !== undefined && active.processHandle.exitCode === null) {
        active.processHandle.kill("SIGTERM")
        await Promise.race([
          new Promise<void>((resolve) => active.processHandle!.once("exit", () => resolve())),
          delay(1_500)
        ])
      }
    }
    await active.connection.close().catch(() => undefined)
  }

  return {
    id: "browser",
    tools: browserUseTools,
    ensureSetup,
    status,
    sessionBackend: (sessionId) => sessionBackends.get(sessionId),
    setSessionBackend: (sessionId, backend) => sessionBackends.set(sessionId, backend),
    acceptExtensionConnection: (socket) => {
      runtimes.delete("extension")
      extensionRelay.accept(socket)
    },
    waitForExtensionConnection: async () => {
      if (extensionEndpoint() !== undefined || extensionRelay.connected()) return
      await extensionRelay.connect()
    },
    onExtensionConnectionChange: extensionRelay.onConnectionChange,
    openDevelopmentExtensionFolder: () =>
      openBrowserExtensionDevelopmentFolder(developmentExtensionPath),
    openDevelopmentExtensionPage: () =>
      openBrowserExtensionDevelopmentPage(developmentExtensionPath),
    openDevelopmentExtensionInstaller: () =>
      openBrowserExtensionDevelopmentInstaller(developmentExtensionPath),
    openExtensionWebStore: () => openBrowserExtensionWebStore(),
    extensionArchivePath: () => extensionArchive,
    extensionIconPath: () => join(developmentExtensionPath, "icons", "128.png"),
    configureExtensionRelay: (serverBaseUrl) => {
      prepareBrowserExtension(dataDir, serverBaseUrl)
    },
    invoke: async (context, toolName, args) => {
      if (toolName === "backends") {
        const extension = browserExtensionInstallation()
        return jsonResult({
          preferred: sessionBackends.get(context.sessionId),
          managed: { available: status().backend !== "missing", engine: "codevisor-cdp" },
          extension: {
            available: extension.bundled,
            bundled: extension.bundled,
            installed: extension.installed,
            installationState: extension.installationState,
            browserOpen: userChromiumIsRunning(),
            connectionState:
              extensionEndpoint() !== undefined || extensionRelay.connected()
                ? "connected"
                : "needs_setup",
            connected: extensionEndpoint() !== undefined || extensionRelay.connected(),
            engine: "codevisor-cdp-relay",
            extensionId: CODEVISOR_BROWSER_EXTENSION_ID,
            installPath: developmentExtensionPath,
            detail:
              "Codevisor's composer handles extension setup. A connected relay is the authoritative readiness signal."
          }
        })
      }
      if (toolName === "connection_status") {
        const backend = sessionBackends.get(context.sessionId)
        if (backend === undefined)
          return jsonResult({
            backend: "unconfigured",
            connectionState: "needs_selection",
            connected: false
          })
        if (backend === "extension") return extensionConnectionResult()
        return jsonResult({ backend, connectionState: "connected", connected: true })
      }
      if (toolName === "use_backend") {
        const backend = args.backend
        if (backend !== "managed" && backend !== "extension") {
          return textToolResult("backend must be managed or extension", true)
        }
        if (
          backend === "extension" &&
          !existsSync(join(developmentExtensionPath, "manifest.json"))
        ) {
          return textToolResult("The Codevisor Chrome extension resources are missing", true)
        }
        sessionBackends.set(context.sessionId, backend)
        if (backend === "extension") return extensionConnectionResult()
        return jsonResult({ backend, engine: "codevisor-cdp", connectionState: "connected" })
      }
      if (!browserUseTools.some((candidate) => candidate.name === toolName)) {
        return textToolResult(`Unknown Browser Use tool: ${toolName}`, true)
      }
      const backend = sessionBackends.get(context.sessionId) ?? "managed"
      sessionBackends.set(context.sessionId, backend)
      let effectiveTool = toolName
      let effectiveArgs = args
      if (toolName === "openTabs") {
        effectiveTool = "tabs"
        effectiveArgs = { action: "list" }
      } else if (toolName === "claimTab") {
        effectiveTool = "tabs"
        effectiveArgs = {
          action: "select",
          ...(typeof args.id === "string" ? { id: args.id } : { index: args.index })
        }
      }
      if (
        backend === "extension" &&
        extensionEndpoint() === undefined &&
        !extensionRelay.connected()
      )
        return textToolResult("Chrome is not connected to Codevisor", true)
      try {
        const active = await runtime(context, backend)
        if (effectiveTool === "playwright.waitForEvent") {
          return await invokeTool(context, active, effectiveTool, effectiveArgs)
        }
        return await serialized(active, () =>
          invokeTool(context, active, effectiveTool, effectiveArgs)
        )
      } catch (cause) {
        return textToolResult(cause instanceof Error ? cause.message : String(cause), true)
      }
    },
    closeSession: async (sessionId) => {
      sessionBackends.delete(sessionId)
      const suffix = `:${sessionId}`
      const keys = new Set(
        [...selectedTargets.keys(), ...sessionTargets.keys(), ...sessionDispositions.keys()].filter(
          (key) => key.endsWith(suffix)
        )
      )
      for (const key of keys) {
        const targets = new Set(sessionTargets.get(key)?.keys() ?? [])
        const selected = selectedTargets.get(key)
        if (selected !== undefined) targets.add(selected)
        selectedTargets.delete(key)
        sessionTargets.delete(key)
        sessionDispositions.delete(key)
        const active = runtimes.get(key.slice(0, -(sessionId.length + 1)))
        const resolved = await active?.catch(() => undefined)
        if (resolved === undefined) continue
        for (const targetId of targets) {
          const tabSessionId = resolved.sessions.get(targetId)
          if (tabSessionId !== undefined) {
            await resolved.connection
              .send("Target.detachFromTarget", { sessionId: tabSessionId })
              .catch(() => undefined)
          }
          resolved.sessions.delete(targetId)
          resolved.snapshots.delete(targetId)
        }
      }
    },
    close: async () => {
      const active = [...runtimes.values()]
      runtimes.clear()
      stopRelayLifecycle()
      await extensionRelay.close()
      await Promise.all(
        active.map(async (pending) => {
          const resolved = await pending.catch(() => undefined)
          if (resolved !== undefined) await closeRuntime(resolved)
        })
      )
    }
  }
}
