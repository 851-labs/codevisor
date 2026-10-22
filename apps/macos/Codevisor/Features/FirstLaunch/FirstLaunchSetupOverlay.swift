import CodevisorCore
import SwiftUI

struct FirstLaunchSetupOverlay: View {
  let setup: FirstLaunchSetup

  var body: some View {
    ZStack {
      if coversApp {
        ZStack {
          Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
          if setup.presentation == .visible {
            FirstLaunchSetupView(setup: setup)
              .transition(.opacity)
          }
        }
        .transition(.opacity)
      }
    }
    .animation(.smooth(duration: 0.35), value: setup.presentation)
    .allowsHitTesting(coversApp)
  }

  private var coversApp: Bool {
    setup.presentation == .waiting || setup.presentation == .visible
  }
}
