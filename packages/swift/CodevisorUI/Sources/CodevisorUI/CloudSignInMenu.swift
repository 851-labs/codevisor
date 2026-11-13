#if os(macOS)
  import AppKit
  import CodevisorCore
  import SwiftUI

  struct CloudSignInMenu: View {
    let cloud: CloudAccountController
    let signIn: (CloudSignInProvider) -> Void
    let signInWithEmail: () -> Void

    var body: some View {
      CloudSignInMenuButton(title: "Sign In", items: items)
        .fixedSize()
        .disabled(items.isEmpty)
    }

    private var items: [CloudSignInMenuItem] {
      var items: [CloudSignInMenuItem] = []
      if cloud.supportsGitHubSignIn {
        items.append(.init(title: "Sign in with GitHub", image: gitHubMark) { signIn(.github) })
      }
      if cloud.supportsAppleSignIn {
        items.append(.init(title: "Sign in with Apple", image: symbol("apple.logo")) { signIn(.apple) })
      }
      if cloud.supportsEmailSignIn {
        items.append(.init(title: "Sign in with Email", image: symbol("envelope"), action: signInWithEmail))
      }
      if cloud.developmentAccountAvailable {
        items.append(
          .init(title: "Use Development Account", image: symbol("hammer")) {
            Task { await cloud.signInWithDevelopmentAccount() }
          })
      }
      return items
    }

    private var gitHubMark: NSImage? {
      let image = Bundle.module.image(forResource: CodevisorSymbol.gitHubMark.rawValue)
      image?.isTemplate = true
      return image
    }

    private func symbol(_ name: String) -> NSImage? {
      NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
  }
#endif
