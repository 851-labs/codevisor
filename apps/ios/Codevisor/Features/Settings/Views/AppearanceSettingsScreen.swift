import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Appearance

struct AppearanceSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    List {
      Section("Mode") {
        Picker(
          "Appearance",
          selection: Binding(
            get: { environment.settings.settings.themeMode },
            set: { environment.settings.setThemeMode($0) }
          )
        ) {
          Text("Light").tag(ThemeMode.light)
          Text("Dark").tag(ThemeMode.dark)
          Text("System").tag(ThemeMode.system)
        }
        .pickerStyle(.segmented)
      }
    }
    .navigationTitle("Appearance")
    .navigationBarTitleDisplayMode(.inline)
  }
}
