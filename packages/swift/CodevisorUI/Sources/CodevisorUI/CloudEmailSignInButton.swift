import CodevisorCore
import SwiftUI

public struct CloudEmailSignInButton: View {
  private let action: () -> Void

  public init(action: @escaping () -> Void) { self.action = action }

  public var body: some View {
    CloudSignInProviderButton(title: title, icon: .system("envelope.fill"), action: action)
  }

  private var title: String {
    #if os(macOS)
      "Sign in with Email…"
    #else
      "Sign in with email"
    #endif
  }
}
