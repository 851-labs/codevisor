import CodevisorCore
import SwiftUI

public struct PluginCatalogRow: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: ServerPluginCatalogEntry
  let isInstalled: Bool
  let isInstalling: Bool
  let onInstall: () -> Void

  public init(
    entry: ServerPluginCatalogEntry,
    isInstalled: Bool,
    isInstalling: Bool,
    onInstall: @escaping () -> Void
  ) {
    self.entry = entry
    self.isInstalled = isInstalled
    self.isInstalling = isInstalling
    self.onInstall = onInstall
  }

  private var subject: PluginModerationSubject { PluginModerationSubject(catalogEntry: entry) }

  public var body: some View {
    let restriction = environment.pluginAccess.restriction(for: subject)
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.name).font(.headline)
        Text(entry.publisher).font(.caption).foregroundStyle(.secondary)
        Text(entry.description).font(.callout).foregroundStyle(.secondary)
        PluginCapabilityChips(capabilities: entry.capabilities)
          .padding(.top, 2)
        if let restriction {
          Text(restriction).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      PluginSafetyButton(subject: subject)
      PluginInstallControl(
        isInstalled: isInstalled, isInstalling: isInstalling, isRestricted: restriction != nil, onInstall: onInstall)
    }
    .padding(.vertical, 4)
  }
}

private struct PluginInstallControl: View {
  let isInstalled: Bool
  let isInstalling: Bool
  let isRestricted: Bool
  let onInstall: () -> Void

  var body: some View {
    if isInstalling {
      ProgressView().controlSize(.small)
    } else {
      Button(isInstalled ? "Installed" : "Install", action: onInstall)
        .buttonStyle(.bordered)
        .disabled(isInstalled || isRestricted)
    }
  }
}
