import CodevisorCore
import CodevisorUI
import SwiftUI

struct CloudAccountScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var openedPage: CloudAccountPage?
  @State private var showsEmailSignIn = false

  var body: some View {
    Form {
      CloudAccountSections(cloud: environment.cloud, signInWithEmail: { showsEmailSignIn = true }) { page in
        SettingsNavigationRow {
          openedPage = page
        } content: {
          CloudAccountPageLabel(page)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showsEmailSignIn) { CloudEmailAuthSheet(cloud: environment.cloud) }
    .navigationDestination(item: $openedPage) { page in
      CloudAccountPageView(page, cloud: environment.cloud)
    }
    .onChange(of: environment.cloud.state.isSignedIn) { _, signedIn in
      if !signedIn, openedPage == .connectedAccounts { openedPage = nil }
    }
  }
}
