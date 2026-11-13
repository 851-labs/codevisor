import CodevisorCore
import SwiftUI

struct CloudSignInMenu: View {
  let cloud: CloudAccountController
  let signIn: (CloudSignInProvider) -> Void
  let signInWithEmail: () -> Void

  var body: some View {
    Menu("Sign In") {
      if cloud.supportsGitHubSignIn {
        item("Sign in with GitHub", icon: CodevisorSymbol.gitHubMark.image) { signIn(.github) }
      }
      if cloud.supportsAppleSignIn {
        item("Sign in with Apple", icon: Image(systemName: "apple.logo")) { signIn(.apple) }
      }
      if cloud.supportsEmailSignIn {
        item("Sign in with Email…", icon: Image(systemName: "envelope"), action: signInWithEmail)
      }
      if cloud.developmentAccountAvailable {
        item("Use Development Account", icon: Image(systemName: "hammer")) {
          Task { await cloud.signInWithDevelopmentAccount() }
        }
      }
    }
    .menuIndicator(.visible)
    .fixedSize()
    .disabled(!offersSignIn)
  }

  private var offersSignIn: Bool {
    cloud.supportsGitHubSignIn || cloud.supportsAppleSignIn || cloud.supportsEmailSignIn
      || cloud.developmentAccountAvailable
  }

  private func item(_ title: String, icon: Image, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label {
        Text(title)
      } icon: {
        icon
      }
      .labelStyle(.titleAndIcon)
    }
  }
}
