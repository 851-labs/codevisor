import CodevisorCore
import SwiftUI

public struct SandboxProviderSection<Row: View>: View {
  let provider: ServerSandboxProvider
  let model: SandboxSettingsModel
  @Binding var sheet: SandboxSettingsSheet?
  let onDelete: () -> Void
  @ViewBuilder let row: (ServerSandboxProfile) -> Row

  public init(
    provider: ServerSandboxProvider,
    model: SandboxSettingsModel,
    sheet: Binding<SandboxSettingsSheet?>,
    onDelete: @escaping () -> Void,
    @ViewBuilder row: @escaping (ServerSandboxProfile) -> Row
  ) {
    self.provider = provider
    self.model = model
    _sheet = sheet
    self.onDelete = onDelete
    self.row = row
  }

  public var body: some View {
    #if os(iOS)
      Section {
        SandboxProviderTitleRow(icon: icon, title: title, onEdit: edit, onDelete: onDelete)
      }
      .listSectionSpacing(8)
      Section {
        rows
        Button("Add Profile…", action: addProfile)
      }
    #else
      Section {
        rows
      } header: {
        HStack(spacing: 6) {
          icon
          Text(title)
        }
      } footer: {
        SettingsListActions {
          Button("Delete…", role: .destructive, action: onDelete)
            .buttonStyle(.bordered)
            .help("Delete this provider and its profiles")
          Button("Edit…", action: edit)
          Button("Add Profile…", action: addProfile)
        }
      }
    #endif
  }

  @ViewBuilder
  private var rows: some View {
    ForEach(profiles, content: row)
    if profiles.isEmpty {
      Text("No profiles yet").foregroundStyle(.secondary)
    }
  }

  private var profiles: [ServerSandboxProfile] { model.profiles(of: provider) }

  private var icon: Image { CodevisorSymbol.sandboxVendor(provider.vendor) }

  private var title: String { model.title(of: provider) }

  private func edit() {
    sheet = .editProvider(provider)
  }

  private func addProfile() {
    sheet = .newProfile(provider)
  }
}
