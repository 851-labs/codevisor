import CodevisorCore
import SwiftUI

struct McpBrowserExtensionStatus: View {
  @Environment(AppEnvironment.self) private var environment
  let machineId: String
  let model: McpGlobalModel

  var body: some View {
    if let configuration = model.browserByMachine[machineId], configuration.chromeAvailable {
      if configuration.chromeConnected {
        Text("Chrome Connected")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize()
      } else if configuration.supportsExtensionFlow, configuration.developmentExtensionPath != nil {
        Button("Install Chrome Extension…") {
          Task { await installExtension() }
        }
        .controlSize(.small)
        .fixedSize()
      }
    }
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
