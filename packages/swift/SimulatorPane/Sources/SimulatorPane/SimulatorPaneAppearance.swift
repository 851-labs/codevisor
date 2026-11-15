import SwiftUI

struct SimulatorPaneAppearance: ViewModifier {
  let model: SimulatorPaneModel
  let isEnabled: Bool

  @Environment(\.scenePhase) private var scenePhase
  @State private var isMounted = false

  func body(content: Content) -> some View {
    content
      .onAppear { isMounted = true }
      .onDisappear { isMounted = false }
      .onChange(of: isOnScreen, initial: true) { _, onScreen in report(onScreen) }
  }

  private var isOnScreen: Bool {
    #if os(iOS)
      isMounted && scenePhase != .background
    #else
      isMounted
    #endif
  }

  private func report(_ onScreen: Bool) {
    guard isEnabled else { return }

    if onScreen {
      model.appeared()
    } else {
      model.disappeared()
    }
  }
}
