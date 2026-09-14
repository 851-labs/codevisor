import CodevisorCore
import CodevisorUI
import SwiftUI

struct CloudSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @State private var showsServer = false
  @State private var showsConnections = false
  @State private var showsEmailSignIn = false

  var body: some View {
    Form {
      CloudAccountSections(
        cloud: environment.cloud,
        manageConnections: { showsConnections = true },
        configureServer: { showsServer = true },
        signInWithEmail: { showsEmailSignIn = true }
      )
    }
    .settingsPaneFormStyle(theme)
    .sheet(isPresented: $showsEmailSignIn) { CloudEmailAuthSheet(cloud: environment.cloud) }
    .sheet(isPresented: $showsServer) {
      NavigationStack {
        CloudServerSettings(cloud: environment.cloud)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showsServer = false }
            }
          }
      }
      .frame(width: 460, height: 340)
    }
    .sheet(isPresented: $showsConnections) {
      NavigationStack {
        CloudConnectedAccountsSettings(cloud: environment.cloud)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showsConnections = false }
            }
          }
      }
      .frame(width: 460, height: 400)
    }
  }
}
