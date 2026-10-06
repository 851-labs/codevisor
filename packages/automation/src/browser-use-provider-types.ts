import type { WebSocket } from "ws"

import type { AutomationToolProvider } from "./automation-provider.js"
import type { BrowserPreviewSubscription, BrowserPreviewViewer } from "./browser-preview.js"

export type BrowserBackend = "managed" | "extension" | "builtin"
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
  /** Called only between responses, never for steering input during an active turn. */
  readonly beginTurn: (sessionId: string, backend: BrowserBackend) => Promise<void>
  readonly acceptExtensionConnection: (socket: WebSocket) => void
  readonly onExtensionConnectionChange: (listener: (connected: boolean) => void) => () => void
  /** Rejects when the opener (Finder, Chrome, xdg-open) could not be launched. */
  readonly openDevelopmentExtensionFolder: () => Promise<void>
  readonly openDevelopmentExtensionPage: () => Promise<void>
  readonly openDevelopmentExtensionInstaller: () => Promise<void>
  readonly openExtensionWebStore: () => Promise<void>
  readonly extensionArchivePath: () => string
  readonly extensionIconPath: () => string
  readonly configureExtensionRelay: (serverBaseUrl: string) => void
  /// A live view of the tab the session's agent is driving.
  readonly subscribePreview?: (
    sessionId: string,
    viewer: BrowserPreviewViewer
  ) => BrowserPreviewSubscription
}
