import CodevisorCore
import SwiftUI

public struct PluginCatalogDetail: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var confirmingBlock = false
  let entry: ServerPluginCatalogEntry
  let client: any CodevisorServerClienting
  let isInstalled: Bool
  let isInstalling: Bool
  let onAdd: () -> Void

  public init(
    entry: ServerPluginCatalogEntry,
    client: any CodevisorServerClienting,
    isInstalled: Bool,
    isInstalling: Bool,
    onAdd: @escaping () -> Void
  ) {
    self.entry = entry
    self.client = client
    self.isInstalled = isInstalled
    self.isInstalling = isInstalling
    self.onAdd = onAdd
  }

  private var subject: PluginModerationSubject { PluginModerationSubject(catalogEntry: entry) }

  public var body: some View {
    let restriction = environment.pluginAccess.restriction(for: subject)
    Form {
      Section {
        HStack(spacing: 14) {
          PluginCatalogIcon(entry: entry, client: client, side: 56)
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.title3.weight(.semibold))
            Text(entry.publisher).font(.callout).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          if !isInstalled {
            PluginCatalogAddButton(
              isInstalled: false, isInstalling: isInstalling, isRestricted: restriction != nil, onAdd: onAdd,
              onOpen: {}, prominent: true)
          }
        }
        .padding(.vertical, 4)
      } footer: {
        if let restriction { Text(restriction) }
      }
      Section {
        if !entry.description.isEmpty { Text(entry.description) }
        if !entry.capabilities.isEmpty { PluginCapabilityChips(capabilities: entry.capabilities) }
        PluginAgeRatingRow(subject: subject)
        if let docs = entry.docsUrl.flatMap(URL.init(string:)) { Link("Website", destination: docs) }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(entry.name)
    .toolbar {
      if !subject.isFirstParty {
        ToolbarItem {
          Menu {
            PluginBlockMenuItem(subject: subject) { confirmingBlock = true }
          } label: {
            Label("More", systemImage: "ellipsis.circle")
          }
        }
      }
    }
    .pluginBlockConfirmation(subject: subject, isPresented: $confirmingBlock)
  }
}
