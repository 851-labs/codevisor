import CodevisorCore
import SwiftUI

struct GeneralSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    List {
      Section {
        Picker("Delete Archived Chats", selection: retention) {
          ForEach(ArchivedChatRetention.allCases) { option in
            Text(option.title).tag(option)
          }
        }
        .accessibilityIdentifier("settings.archivedChatRetention")
      } header: {
        Text("Archived Chats")
      } footer: {
        Text(
          "Archived chats and their attachments are deleted on all your machines after this long. So are images left in a draft."
        )
      }
    }
    .navigationTitle("General")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var setting: ArchivedChatRetentionSetting {
    ArchivedChatRetentionSetting(configSync: environment.configSync)
  }

  private var retention: Binding<ArchivedChatRetention> {
    Binding(
      get: { setting.current },
      set: { setting.choose($0) }
    )
  }
}
