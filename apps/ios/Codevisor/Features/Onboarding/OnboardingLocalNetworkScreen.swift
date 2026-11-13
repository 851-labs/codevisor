import CodevisorCore
import SwiftUI
import UIKit

struct OnboardingLocalNetworkScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.scenePhase) private var scenePhase
  @State private var monitor: LocalNetworkPermissionMonitor?

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: 96)
      OnboardingHero(symbol: "network", title: "Local Network", subtitle: subtitle)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .safeAreaInset(edge: .bottom) {
      OnboardingLocalNetworkActions(
        phase: phase,
        allow: { monitor = LocalNetworkPermissionMonitor() },
        continueAnyway: { environment.setLocalNetworkAccess(.requested) },
        later: { environment.setLocalNetworkAccess(.deferred) }
      )
    }
    .task(id: LocalNetworkWatch(isRequested: monitor != nil, scenePhase: scenePhase)) {
      guard let monitor, scenePhase == .active else { return }
      await monitor.watch(localServer: nil)
    }
    .onChange(of: monitor?.status) { _, status in finishIfReachable(status) }
  }

  private var phase: OnboardingLocalNetworkPhase {
    guard let monitor else { return .choosing }
    if case .blocked = monitor.status { return .blocked }
    return .checking
  }

  private var subtitle: String {
    switch phase {
    case .choosing, .checking:
      "Connect to your machines directly over the local network when available."
    case .blocked:
      "Codevisor can't reach your local network. Turn on Local Network for Codevisor in Settings, or continue and connect through Codevisor Cloud."
    }
  }

  private func finishIfReachable(_ status: LocalNetworkStatus?) {
    guard status == .allowed || status == .unavailable else { return }
    environment.setLocalNetworkAccess(.requested)
  }
}

private struct LocalNetworkWatch: Hashable {
  let isRequested: Bool
  let scenePhase: ScenePhase
}

private enum OnboardingLocalNetworkPhase {
  case choosing
  case checking
  case blocked
}

private struct OnboardingLocalNetworkActions: View {
  @Environment(\.openURL) private var openURL
  let phase: OnboardingLocalNetworkPhase
  let allow: () -> Void
  let continueAnyway: () -> Void
  let later: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      primaryButton
        .buttonStyle(OnboardingFilledButtonStyle(background: .accentColor, foreground: .white))
      secondaryButton
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var primaryButton: some View {
    switch phase {
    case .choosing:
      Button("Allow Local Network Access", action: allow)
        .accessibilityIdentifier("onboarding.localNetwork.allow")
    case .checking:
      Button {
      } label: {
        ProgressView().tint(.white)
      }
      .disabled(true)
    case .blocked:
      Button("Open Settings", action: openAppSettings)
        .accessibilityIdentifier("onboarding.localNetwork.openSettings")
    }
  }

  @ViewBuilder
  private var secondaryButton: some View {
    if phase == .blocked {
      Button("Continue Without It", action: continueAnyway)
        .accessibilityIdentifier("onboarding.localNetwork.continue")
    } else {
      Button("Set Up Later", action: later)
        .accessibilityIdentifier("onboarding.localNetwork.later")
    }
  }

  private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    openURL(url)
  }
}
