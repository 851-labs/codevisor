import { textToolResult } from "./automation-provider.js"
import type { NativeBrowserHost } from "./browser-cdp-engine.js"
import type { BrowserExtensionInstallation } from "./browser-extension-relay.js"
import type { BrowserHostAnswer, BrowserHostProbe } from "./browser-host-registry.js"
import type { BrowserBackend, BrowserClientPlatform } from "./browser-use-provider-types.js"

export type BrowserExtensionState =
  | "connected"
  | "installed_not_connected"
  | "not_connected"
  | "not_installed"
  | "chrome_not_installed"

export type BuiltinBrowserState = {
  readonly probes: ReadonlyArray<BrowserHostProbe>
  readonly lostHost?: string | undefined
} & (
  | { readonly host: NativeBrowserHost; readonly reason?: never }
  | { readonly host?: never; readonly reason: string }
)

export interface BrowserLabel {
  readonly backend: BrowserBackend
  readonly host: string
}

const lostTabs = (host: string) =>
  `The Codevisor app on ${host} disconnected, so this chat's built-in browser tabs were lost.`

export const browserExtensionState = (inputs: {
  readonly connected: boolean
  readonly chromeAvailable: boolean
  readonly installationState: BrowserExtensionInstallation["installationState"]
}): BrowserExtensionState => {
  if (inputs.connected) return "connected"
  if (!inputs.chromeAvailable) return "chrome_not_installed"
  if (inputs.installationState === "installed") return "installed_not_connected"
  return inputs.installationState === "not_installed" ? "not_installed" : "not_connected"
}

export const browserStatusReport = (inputs: {
  readonly selected: BrowserBackend | undefined
  readonly platform: BrowserClientPlatform | undefined
  readonly managedError: string | undefined
  readonly builtin: BuiltinBrowserState
  readonly extension: BrowserExtensionState
}) => ({
  selected: inputs.selected ?? null,
  ...(inputs.platform === undefined ? {} : { user: { platform: inputs.platform } }),
  managed: {
    state: inputs.managedError === undefined ? "ready" : "unavailable",
    visibleToUser: false,
    ...(inputs.managedError === undefined ? {} : { reason: inputs.managedError })
  },
  builtin: builtinReport(inputs.builtin),
  extension: {
    state: inputs.extension,
    visibleToUser: inputs.extension === "connected"
  }
})

export type BrowserStatusReport = ReturnType<typeof browserStatusReport>

const availability = (report: BrowserStatusReport) =>
  `Current availability:\n${JSON.stringify(report, null, 2)}`

export const noBrowserSelectedResult = (report: BrowserStatusReport) =>
  textToolResult(
    `No browser is selected for this chat. Pick one with browser.use_backend({ backend }): managed (headless; the user can't see it), builtin (this chat's browser pane in the Codevisor Mac app), or extension (the user's own Chrome). ${availability(report)}`,
    true
  )

export const chromeNotConnectedResult = (report: BrowserStatusReport) =>
  textToolResult(`Chrome is not connected to Codevisor. ${availability(report)}`, true)

export const builtinLostResult = (lostHost: string | undefined) =>
  textToolResult(
    `${lostHost === undefined ? "The built-in browser disconnected." : lostTabs(lostHost)} The interrupted action was NOT retried; its outcome may be unknown. The next browser call reconnects to the Codevisor window that shows this chat, and fails if no Mac app can open it. Discard old tab IDs, locators and snapshots, then open or observe a new tab before continuing.`,
    true
  )

export const builtinUnreachableMessage = (reason: string) =>
  `The built-in browser can't be reached, so nothing ran. ${reason} Ask the user to open this chat in the Codevisor Mac app, or pick another browser with browser.use_backend (managed is headless, so the user can't see it).`

export const browserLabel = (
  backend: BrowserBackend,
  nativeHost: NativeBrowserHost | undefined
): BrowserLabel => ({ backend, host: labelHost(backend, nativeHost) })

const labelHost = (backend: BrowserBackend, nativeHost: NativeBrowserHost | undefined) => {
  if (nativeHost !== undefined) return builtinWhere(nativeHost)
  if (backend === "extension") return "The user's own Chrome"
  return "Headless Chromium on this server; the user can't see it"
}

const builtinWhere = ({ name, showing }: NativeBrowserHost) => {
  if (showing)
    return `This chat's browser pane in the Codevisor window on ${name} that shows this chat`
  return `This chat's browser pane in Codevisor on ${name}, in the background: the chat isn't open in a window there, so its tabs show when the user opens it`
}

const builtinReport = (builtin: BuiltinBrowserState) => ({
  ...builtinReadiness(builtin),
  macs: builtin.probes.map(({ host, answer }) => ({
    name: host.name,
    state: macStates[answer]
  })),
  ...(builtin.lostHost === undefined ? {} : { lost: lostTabs(builtin.lostHost) })
})

const builtinReadiness = (builtin: BuiltinBrowserState) => {
  if (builtin.host === undefined)
    return {
      state: "unavailable",
      visibleToUser: false,
      reason: `${builtin.reason} Built-in browser calls fail until a Codevisor Mac app can open this chat; they never fall back to another browser.`
    }
  return {
    state: "ready",
    visibleToUser: builtin.host.showing,
    host: builtinWhere(builtin.host)
  }
}

const macStates: Record<BrowserHostAnswer, string> = {
  focused: "shows this chat in its focused window",
  showing: "shows this chat",
  available: "can open this chat in the background",
  unavailable: "can't open this chat",
  unresponsive: "not responding; check that Mac for a blocking dialog",
  disconnected: "disconnected"
}
