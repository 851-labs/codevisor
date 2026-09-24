import CodevisorCore
import SwiftUI

/// Browser Use's browser choice, on the machine row it belongs to. The
/// preference is stored per machine and never syncs, so putting it on the
/// server's row (as the per-machine pages used to) read like a property of
/// the server. Here it reads correctly: this Mac uses the extension, that
/// one uses Chromium.
struct McpBrowserPicker: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let machineId: String
  let model: McpGlobalModel

  private static let choices = [
    ("chrome", "Codevisor Extension"), ("managed", "Chromium"), ("builtin", "Built-in Browser"),
  ]

  var body: some View {
    if let configuration = model.browserByMachine[machineId] {
      Menu {
        ForEach(Self.choices, id: \.0) { value, label in
          Button {
            Task { await select(value) }
          } label: {
            if (configuration.preferredBrowser ?? "builtin") == value {
              Label(label, systemImage: "checkmark")
            } else {
              Text(label)
            }
          }
        }
        if configuration.chromeAvailable,
          configuration.supportsExtensionFlow,
          !configuration.chromeConnected,
          configuration.developmentExtensionPath != nil
        {
          Divider()
          Button("Install Chrome Extension…") {
            Task { await installExtension() }
          }
        }
      } label: {
        Text(label(configuration))
      }
      .controlSize(.small)
      .fixedSize()
      .tint(theme.isSystem ? nil : theme.textPrimary)
    }
  }

  private func label(_ configuration: ServerBrowserUseConfiguration) -> String {
    switch configuration.preferredBrowser {
    case "chrome": configuration.chromeConnected ? "Codevisor Extension" : "Extension · Setup"
    case "managed": "Chromium"
    default: "Built-in Browser"
    }
  }

  private func select(_ value: String) async {
    do {
      _ = try await environment.machines.client(for: machineId).setPreferredBrowser(value)
      model.actionError = nil
      await model.load(in: environment)
    } catch {
      model.actionError = ErrorReporter.userFacingMessage(for: error)
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
