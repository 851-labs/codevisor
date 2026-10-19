import CodevisorCore
import SwiftUI

struct OnboardingLocalNetworkScreen: View {
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: 96)
      OnboardingHero(
        symbol: "network",
        title: "Local Network",
        subtitle: "Connect to your machines directly over the local network when available."
      )
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 12) {
        Button("Allow Local Network Access") { environment.setLocalNetworkAccess(.requested) }
          .buttonStyle(OnboardingFilledButtonStyle(background: .accentColor, foreground: .white))
          .accessibilityIdentifier("onboarding.localNetwork.allow")
        Text("iOS will ask you to confirm.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("Set Up Later") { environment.setLocalNetworkAccess(.deferred) }
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 44)
          .accessibilityIdentifier("onboarding.localNetwork.later")
      }
      .padding(.horizontal, 20)
      .padding(.top, 12)
      .padding(.bottom, 12)
    }
  }
}
