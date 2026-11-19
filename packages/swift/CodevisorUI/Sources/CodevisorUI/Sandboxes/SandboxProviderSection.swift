import CodevisorCore
import SwiftUI

public struct SandboxProviderSection<Row: View>: View {
  let provider: ServerSandboxProvider
  let model: SandboxSettingsModel
  @Binding var sheet: SandboxSettingsSheet?
  @ViewBuilder let row: (ServerSandboxProfile) -> Row

  public init(
    provider: ServerSandboxProvider,
    model: SandboxSettingsModel,
    sheet: Binding<SandboxSettingsSheet?>,
    @ViewBuilder row: @escaping (ServerSandboxProfile) -> Row
  ) {
    self.provider = provider
    self.model = model
    _sheet = sheet
    self.row = row
  }

  public var body: some View {
    Section {
      ForEach(profiles, content: row)
      if profiles.isEmpty {
        Text("No profiles yet").foregroundStyle(.secondary)
      }
      #if os(iOS)
        Button("Add Profile…", action: addProfile)
      #endif
    } header: {
      header
    } footer: {
      #if os(macOS)
        SettingsListActions {
          Button("Edit Provider…", action: edit)
          Button("Add Profile…", action: addProfile)
        }
      #endif
    }
  }

  private var profiles: [ServerSandboxProfile] { model.profiles(of: provider) }

  private var header: some View {
    HStack(spacing: 6) {
      CodevisorSymbol.sandboxVendor(provider.vendor)
      Text(model.title(of: provider))
      #if os(iOS)
        Spacer()
        Button("Edit", action: edit)
          .font(.subheadline)
          .accessibilityLabel("Edit Provider")
      #endif
    }
    .textCase(nil)
  }

  private func edit() {
    sheet = .editProvider(provider)
  }

  private func addProfile() {
    sheet = .newProfile(provider)
  }
}
