import type { AutomationToolProvider } from "./automation-provider.js"
import type WebSocket from "ws"

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
