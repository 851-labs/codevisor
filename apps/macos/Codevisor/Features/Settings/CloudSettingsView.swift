import CodevisorCore
import CodevisorUI
import SwiftUI

struct CloudSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var showsEmailSignIn = false

  var body: some View {
    Form {
      CloudAccountSections(cloud: environment.cloud, signInWithEmail: { showsEmailSignIn = true }) { page in
        NavigationLink(value: SettingsPaneRoute.cloudAccount(page)) {
          CloudAccountPageLabel(page, cloud: environment.cloud)
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showsEmailSignIn) { CloudEmailAuthSheet(cloud: environment.cloud) }
  }
}
