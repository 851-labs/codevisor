import CodevisorCore
import SwiftUI

struct PluginCatalogTile: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: ServerPluginCatalogEntry
  let client: any CodevisorServerClienting
  let isInstalled: Bool
  let isInstalling: Bool
  let onAdd: () -> Void
  let onOpen: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onOpen) {
        HStack(spacing: 12) {
          PluginCatalogIcon(entry: entry, client: client, side: 36)
          Text(entry.name).lineLimit(1)
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      PluginCatalogAddButton(
        isInstalled: isInstalled, isInstalling: isInstalling, isRestricted: isRestricted, onAdd: onAdd,
        onOpen: onOpen)
    }
    .padding(.vertical, 6)
  }

  private var isRestricted: Bool {
    environment.pluginAccess.restriction(for: PluginModerationSubject(catalogEntry: entry)) != nil
  }
}

struct PluginCatalogAddButton: View {
  let isInstalled: Bool
  let isInstalling: Bool
  let isRestricted: Bool
  let onAdd: () -> Void
  let onOpen: () -> Void
  var prominent = false

  var body: some View {
    if isInstalling {
      ProgressView().controlSize(.small).frame(minWidth: 56)
    } else if isInstalled {
      styled(Button("Open", action: onOpen))
    } else {
      styled(Button("Add", action: onAdd)).disabled(isRestricted)
    }
  }

  @ViewBuilder
  private func styled(_ button: Button<Text>) -> some View {
    if prominent {
      button.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
    } else {
      button.buttonStyle(.bordered).buttonBorderShape(.capsule)
    }
  }
}
