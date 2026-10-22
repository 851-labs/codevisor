import CodevisorCore
import CodevisorUI
import SwiftUI

struct FirstLaunchSetupOverlay: View {
  let setup: FirstLaunchSetup
  let landing: FirstLaunchLanding
  @State private var phase = FirstLaunchOverlayPhase.covering
  @State private var size = CGSize.zero
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let composerStyle = ComposerCardStyle()

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)
        .ignoresSafeArea()
        .opacity(phase == .covering ? 1 : 0)
      if showsSetup {
        setupView
          .transition(.opacity)
      }
    }
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: {
      size = $0
    }
    .allowsHitTesting(phase == .covering)
    .animation(.smooth(duration: 0.35), value: setup.presentation == .visible)
    .onChange(of: setup.presentation) { _, presentation in leave(after: presentation) }
  }

  private var setupView: some View {
    FirstLaunchSetupView(
      setup: setup,
      stage: FirstLaunchStage(
        style: style,
        isLeaving: phase == .leaving,
        targets: targets,
        windowSize: size,
        composerCornerRadius: composerStyle.cornerRadius
      )
    )
  }

  private var showsSetup: Bool {
    phase != .gone && (setup.presentation == .visible || phase == .leaving)
  }

  private var style: FirstLaunchDismissStyle {
    .current(reduceMotion: reduceMotion)
  }

  private var targets: [FirstLaunchLandingTarget: CGRect] {
    Dictionary(
      uniqueKeysWithValues: [FirstLaunchLandingTarget.composer, .modelChip, .projectChip].compactMap { key in
        target(key).map { (key, $0) }
      })
  }

  private func target(_ key: FirstLaunchLandingTarget) -> CGRect? {
    landing.frame(for: key)
  }

  private func leave(after presentation: FirstLaunchPresentation) {
    guard phase == .covering, presentation == .dismissed || presentation == .handedOff else { return }
    let showsFlourish = setup.wasShown && presentation == .dismissed
    let animation = showsFlourish ? style.animation : FirstLaunchDismissStyle.crossfade.animation
    if showsFlourish, style == .flyIntoComposer { landing.catchCard() }
    withAnimation(animation) {
      phase = .leaving
    } completion: {
      phase = .gone
    }
  }
}
