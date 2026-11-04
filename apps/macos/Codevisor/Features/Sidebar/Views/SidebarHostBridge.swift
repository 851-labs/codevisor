import SwiftUI

@MainActor
@Observable
final class SidebarHostBridge {
  private(set) var revealCount = 0
  @ObservationIgnored var openSettings: OpenSettingsAction?

  func recordReveal() {
    revealCount += 1
  }
}
