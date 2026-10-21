import { textToolResult } from "./automation-provider.js"
import type { BrowserExtensionInstallation } from "./browser-extension-relay.js"
import type { BrowserHostState } from "./browser-host-registry.js"
import type { BrowserBackend, BrowserClientPlatform } from "./browser-use-provider-types.js"

export type BrowserExtensionState =
  | "connected"
  | "installed_not_connected"
  | "not_connected"
  | "not_installed"
  | "chrome_not_installed"

export interface BuiltinBrowserState {
  readonly ready: boolean
  readonly reason?: string | undefined
  readonly host?: string | undefined
  readonly lostHost?: string | undefined
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
  builtin: {
    ...(inputs.builtin.ready
      ? {
          state: "ready",
          visibleToUser: true,
          host: `This chat's browser pane in Codevisor on ${inputs.builtin.host}`
        }
      : {
          state: "unavailable",
          visibleToUser: false,
          reason: inputs.builtin.reason,
          fallback: "Calls run in the headless managed browser instead."
        }),
    ...(inputs.builtin.lostHost === undefined ? {} : { lost: lostTabs(inputs.builtin.lostHost) })
  },
  extension: { state: inputs.extension, visibleToUser: inputs.extension === "connected" }
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

export const builtinLostResult = ({ host, lostHost }: BrowserHostState) =>
  textToolResult(
    `${lostHost === undefined ? "The built-in browser disconnected." : lostTabs(lostHost)} The interrupted action was NOT retried; its outcome may be unknown. The next browser call opens new tabs ${host === undefined ? "in the headless managed browser, which the user can't see" : `in Codevisor on ${host.name}`}. Discard old tab IDs, locators and snapshots, then open or observe a new tab before continuing.`,
    true
  )
