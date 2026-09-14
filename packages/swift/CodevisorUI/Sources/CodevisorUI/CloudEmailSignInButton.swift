import CodevisorCore
import SwiftUI

public struct CloudEmailSignInButton: View {
  private let action: () -> Void

  public init(action: @escaping () -> Void) { self.action = action }

  public var body: some View {
    CloudSignInProviderButton(title: "Sign in with email", icon: .system("envelope"), action: action)
  }
}
