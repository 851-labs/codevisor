import CodevisorCore
import SwiftUI

struct McpBrowserExtensionInstallButton: View {
  @Environment(AppEnvironment.self) private var environment
  let machineId: String
  let model: McpGlobalModel

  var body: some View {
    if let configuration = model.browserByMachine[machineId], offersInstall(configuration) {
      Button("Install Chrome Extension…") {
        Task { await installExtension() }
      }
      .controlSize(.small)
      .fixedSize()
    }
  }

  private func offersInstall(_ configuration: ServerBrowserUseConfiguration) -> Bool {
    configuration.chromeAvailable && !configuration.chromeConnected
      && configuration.supportsExtensionFlow && configuration.developmentExtensionPath != nil
  }

  private func installExtension() async {
    do {
      _ = try await environment.machines.client(for: machineId).installDevelopmentBrowserExtension()
      model.actionError = nil
      await model.load(in: environment)
    } catch {
      model.actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
