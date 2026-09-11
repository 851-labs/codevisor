import CodevisorCore
import CodevisorUI
import SwiftUI

struct CloudAccountScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var showsServer = false
  @State private var showsConnections = false

  var body: some View {
    Form {
      CloudAccountSections(
        cloud: environment.cloud,
        manageConnections: { showsConnections = true },
        configureServer: { showsServer = true }
      )
    }
    .formStyle(.grouped)
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(isPresented: $showsServer) {
      CloudServerSettings(cloud: environment.cloud)
    }
    .navigationDestination(isPresented: $showsConnections) {
      CloudConnectedAccountsSettings(cloud: environment.cloud)
    }
  }
}
