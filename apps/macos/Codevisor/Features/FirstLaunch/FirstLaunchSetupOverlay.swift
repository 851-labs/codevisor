import CodevisorCore
import CodevisorUI
import SwiftUI

struct FirstLaunchSetupOverlay<Content: View>: View {
  let setup: FirstLaunchSetup?
  let landing: FirstLaunchLanding?
  let content: Content
  @State private var phase: FirstLaunchOverlayPhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let composerStyle = ComposerCardStyle()

  init(setup: FirstLaunchSetup?, landing: FirstLaunchLanding?, @ViewBuilder content: () -> Content) {
    self.setup = setup
    self.landing = landing
    self.content = content()
    _phase = State(initialValue: setup == nil ? .gone : .covering)
  }

  var body: some View {
    ZStack {
      content
        .opacity(phase.coversApp ? 0 : 1)
        .accessibilityHidden(phase.coversApp)
        .toolbar(removing: phase.coversApp ? .title : nil)
        .environment(\.firstLaunchCoversApp, phase.coversApp)
      if phase != .gone, let setup {
        FirstLaunchSetupView(
          setup: setup,
          phase: phase,
          composerFrame: landing?.composerFrame,
          composerCornerRadius: composerStyle.cornerRadius
        ) {
          FirstLaunchGetStartedButton(isReady: setup.canGetStarted) { setup.getStarted() }
        }
        .background(FirstLaunchKeyboard(isCovering: phase == .covering) { setup.getStarted() })
        .contentShape(Rectangle())
        .allowsHitTesting(phase.coversApp)
      }
    }
    .onChange(of: setup?.presentation) { _, presentation in leave(after: presentation) }
  }

  private func leave(after presentation: FirstLaunchPresentation?) {
    guard phase == .covering, presentation != .visible else { return }
    if presentation == .dismissed, !reduceMotion, landing?.composerFrame != nil {
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

  private static var morph: Animation { .smooth(duration: 0.45) }
  private static var reveal: Animation { .easeOut(duration: 0.2) }
  private static var crossfadeOut: Animation { .smooth(duration: 0.35) }
}
