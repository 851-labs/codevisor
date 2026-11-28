import SwiftUI

public struct LaunchStartingView: View {
  private let isSlow: Bool
  @State private var spinnerDelayPassed = false

  public init(isSlow: Bool) {
    self.isSlow = isSlow
  }

  public var body: some View {
    CenteredLaunchStack(spacing: 14) {
      LaunchMark()
      ProgressView()
        .controlSize(.small)
        .opacity(showsSpinner ? 1 : 0)
      if isSlow {
        Text("Codevisor is taking a while to start…")
          .font(.callout)
          .foregroundStyle(.secondary)
          .transition(.opacity)
      }
    }
    .animation(.smooth(duration: 0.3), value: isSlow)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isSlow ? "Codevisor is taking a while to start" : "Starting Codevisor")
    .task {
      try? await Task.sleep(for: Self.spinnerDelay)
      withAnimation(.easeIn(duration: 0.2)) { spinnerDelayPassed = true }
    }
  }

  private var showsSpinner: Bool { isSlow || spinnerDelayPassed }

  private static var spinnerDelay: Duration { .milliseconds(500) }
}
