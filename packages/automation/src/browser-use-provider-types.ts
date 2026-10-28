import type { WebSocket } from "ws"

import type { AutomationToolProvider } from "./automation-provider.js"
import type { BrowserHostSocket } from "./browser-host-registry.js"
import type { BrowserPreviewSubscription, BrowserPreviewViewer } from "./browser-preview.js"

export type BrowserBackend = "managed" | "extension" | "builtin"
export type BrowserExtensionSetupMode = "development" | "webStore"
export type BrowserClientPlatform = "macos" | "ios"

export interface BrowserUseProviderStatus extends Readonly<Record<string, unknown>> {
  readonly extensionConnected: boolean
  readonly chromeAvailable: boolean
  readonly extensionSetupMode: BrowserExtensionSetupMode
  readonly unpackedExtensionInstalled?: boolean
  readonly developmentExtensionPath?: string
  readonly extensionArchivePath?: string
}

export interface BrowserUseProvider extends AutomationToolProvider {
  readonly ensureSetup: () => Promise<void>
  readonly status: () => BrowserUseProviderStatus
  readonly sessionBackend: (sessionId: string) => BrowserBackend | undefined
  readonly setSessionBackend: (sessionId: string, backend: BrowserBackend) => void
  readonly beginTurn: (
    sessionId: string,
    options?: { readonly clientPlatform?: BrowserClientPlatform | undefined }
  ) => Promise<void>
  readonly acceptBrowserHost: (socket: BrowserHostSocket) => void
  readonly acceptExtensionConnection: (socket: WebSocket) => void
  readonly acceptNativeHostConnection: (socket: WebSocket) => void
  readonly onExtensionConnectionChange: (listener: (connected: boolean) => void) => () => void
  readonly openDevelopmentExtensionFolder: () => Promise<void>
  readonly openDevelopmentExtensionPage: () => Promise<void>
  readonly openDevelopmentExtensionInstaller: () => Promise<void>
  readonly openExtensionWebStore: () => Promise<void>
  readonly extensionArchivePath: () => string
  readonly extensionIconPath: () => string
  readonly configureExtensionRelay: (serverBaseUrl: string) => void
  readonly subscribePreview?: (
    sessionId: string,
    viewer: BrowserPreviewViewer
  ) => BrowserPreviewSubscription
}
