import CodevisorCore
import CodevisorUI
import SwiftUI

struct FirstLaunchSetupOverlay: View {
  let setup: FirstLaunchSetup
  let landing: FirstLaunchLanding
  @State private var phase = FirstLaunchOverlayPhase.covering
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let composerStyle = ComposerCardStyle()

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)
        .ignoresSafeArea()
        .opacity(phase.coversApp ? 1 : 0)
      if showsSetup {
        FirstLaunchSetupView(
          setup: setup,
          phase: phase,
          composerFrame: landing.composerFrame,
          composerCornerRadius: composerStyle.cornerRadius
        )
        .transition(.opacity)
      }
    }
    .background(FirstLaunchKeyboard(isCovering: phase == .covering) { setup.getStarted() })
    .allowsHitTesting(phase == .covering)
    .animation(.smooth(duration: 0.35), value: setup.presentation == .visible)
    .onChange(of: setup.presentation) { _, presentation in leave(after: presentation) }
  }

  private var showsSetup: Bool {
    phase != .gone && (setup.presentation == .visible || phase.isLeaving)
  }

  private func leave(after presentation: FirstLaunchPresentation) {
    guard phase == .covering, presentation == .dismissed || presentation == .handedOff else { return }
    if setup.wasShown, presentation == .dismissed, !reduceMotion, landing.composerFrame != nil {
      morphIntoComposer()
    } else {
      crossfade()
    }
  }

  private func morphIntoComposer() {
    withAnimation(Self.morph) {
      phase = .morphing
    } completion: {
      withAnimation(Self.reveal) {
        phase = .revealing
      } completion: {
        phase = .gone
      }
    }
  }

  private func crossfade() {
    withAnimation(Self.crossfadeOut) {
      phase = .crossfading
    } completion: {
      phase = .gone
    }
  }

  private static let morph = Animation.smooth(duration: 0.45)
  private static let reveal = Animation.easeOut(duration: 0.2)
  private static let crossfadeOut = Animation.smooth(duration: 0.35)
}
