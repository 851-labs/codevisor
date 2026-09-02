import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import { run } from "./mcp-support.js"

export type McpBrowserOperations = Pick<
  McpManager,
  | "acceptBrowserExtension"
  | "answerQuestion"
  | "browserConfiguration"
  | "browserExtensionArchive"
  | "browserExtensionIcon"
  | "openBrowserExtensionFolder"
  | "openBrowserExtensionInstaller"
  | "openBrowserExtensionWebStore"
  | "openBrowserExtensionsPage"
  | "setBaseUrl"
  | "setBrowserPreference"
>

/// Browser Use setup and extension plumbing, plus the base-URL update that
/// re-points the extension relay when the server binds its port.
export const makeMcpBrowserOperations = (core: McpManagerCore): McpBrowserOperations => {
  const { browserProvider, browserSetupBroker, config, extensionFlowSupported, state } = core

  const browserConfiguration: McpManager["browserConfiguration"] = async () => {
    const status = browserProvider.status()
    return {
      ...(await run(config.db.getBrowserPreference).then((preferredBrowser) =>
        preferredBrowser === undefined ? {} : { preferredBrowser }
      )),
      chromeAvailable: status.chromeAvailable,
      chromeConnected: status.extensionConnected,
      managedAvailable: status.backend !== "missing",
      extensionFlowSupported,
      ...(status.developmentExtensionPath === undefined
        ? {}
        : { developmentExtensionPath: status.developmentExtensionPath })
    }
  }

  return {
    setBaseUrl: (url) => {
      const parsed = new URL(url)
      state.gatewayBaseUrl = `${parsed.protocol}//127.0.0.1:${parsed.port}`
      state.oauthBaseUrl = state.gatewayBaseUrl
      browserProvider.configureExtensionRelay(state.gatewayBaseUrl)
    },
    answerQuestion: (sessionId, questionId, answer) =>
      browserSetupBroker.answerQuestion(sessionId, questionId, answer),
    acceptBrowserExtension: (socket) => browserProvider.acceptExtensionConnection(socket),
    browserConfiguration,
    setBrowserPreference: async (preference) => {
      await run(config.db.setBrowserPreference(preference))
      return browserConfiguration()
    },
    openBrowserExtensionInstaller: async () => {
      browserProvider.openDevelopmentExtensionInstaller()
      return browserConfiguration()
    },
    openBrowserExtensionFolder: async () => {
      browserProvider.openDevelopmentExtensionFolder()
      return browserConfiguration()
    },
    openBrowserExtensionsPage: async () => {
      browserProvider.openDevelopmentExtensionPage()
      return browserConfiguration()
    },
    openBrowserExtensionWebStore: async () => {
      browserProvider.openExtensionWebStore()
      return browserConfiguration()
    },
    browserExtensionArchive: () => browserProvider.extensionArchivePath(),
    browserExtensionIcon: () => browserProvider.extensionIconPath()
  }
}
