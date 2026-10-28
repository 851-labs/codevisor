import CodevisorCore
import SwiftUI

struct McpBrowserExtensionInstallButton: View {
  @Environment(AppEnvironment.self) private var environment
  let machineId: String
  let model: McpGlobalModel

  var body: some View {
    if let configuration = model.browserByMachine[machineId], offersInstall(configuration) {
      Button("Install Chrome Extension…") {
        Task { await installExtension(configuration) }
      }
      .controlSize(.small)
      .fixedSize()
    }
  }

  private func offersInstall(_ configuration: ServerBrowserUseConfiguration) -> Bool {
    configuration.chromeAvailable && !configuration.chromeConnected && configuration.supportsExtensionFlow
      && (configuration.installsFromWebStore || configuration.developmentExtensionPath != nil)
  }

  private func installExtension(_ configuration: ServerBrowserUseConfiguration) async {
    do {
      let client = environment.machines.client(for: machineId)
      if configuration.installsFromWebStore {
        _ = try await client.openBrowserExtensionWebStore()
      } else {
        _ = try await client.installDevelopmentBrowserExtension()
      }
      model.actionError = nil
      await model.load(in: environment)
    } catch {
      model.actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
