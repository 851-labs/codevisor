import CodevisorCoreMac
import SwiftUI

struct ScreenSharingOnScreen: NSViewRepresentable {
  let onChange: @MainActor (Bool) -> Void

  func makeCoordinator() -> ScreenSharingOnScreenReporter { ScreenSharingOnScreenReporter() }

  func makeNSView(context: Context) -> ScreenSharingOnScreenProbe {
    let probe = ScreenSharingOnScreenProbe()
    context.coordinator.follow(probe, report: onChange)
    return probe
  }

  func updateNSView(_ probe: ScreenSharingOnScreenProbe, context: Context) {
    context.coordinator.report = onChange
  }

  static func dismantleNSView(_ probe: ScreenSharingOnScreenProbe, coordinator: ScreenSharingOnScreenReporter) {
    probe.retire()
  }
}
