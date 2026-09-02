import SwiftUI

/// The one visual pattern for cloud sign-in options — GitHub today, Google
/// and friends tomorrow, plus the dev account in development builds. Every
/// provider renders identically (icon slot + title in a bordered button);
/// call sites only choose the icon and the action, so adding a provider can
/// never introduce a new look.
struct CloudSignInProviderButton: View {
  enum Icon {
    /// A brand mark from the asset catalog (template-rendered).
    case asset(String)
    /// An SF Symbol (used for non-brand options like the dev account).
    case system(String)
  }

  let title: String
  let icon: Icon
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label {
        Text(title)
      } icon: {
        iconView
      }
    }
  }

  @ViewBuilder
  private var iconView: some View {
    switch icon {
    case let .asset(name):
      Image(name)
        .resizable()
        .scaledToFit()
        .frame(width: 14, height: 14)
    case let .system(name):
      Image(systemName: name)
        .font(.system(size: 13, weight: .medium))
    }
  }
}
