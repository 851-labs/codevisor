import CodevisorCoreMac
import SwiftUI

struct MachineDesktopOnScreen: NSViewRepresentable {
  let onChange: @MainActor (Bool) -> Void

  func makeNSView(context: Context) -> ScreenSharingOnScreenProbe {
    let probe = ScreenSharingOnScreenProbe()
    probe.onChange = deferred
    return probe
  }

  func updateNSView(_ probe: ScreenSharingOnScreenProbe, context: Context) {
    probe.onChange = deferred
  }

  static func dismantleNSView(_ probe: ScreenSharingOnScreenProbe, coordinator: ()) {
    probe.retire()
  }

  private var deferred: (Bool) -> Void {
    { [onChange] onScreen in DispatchQueue.main.async { onChange(onScreen) } }
  }
}
