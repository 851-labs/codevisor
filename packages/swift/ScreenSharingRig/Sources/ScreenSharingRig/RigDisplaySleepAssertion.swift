#if os(macOS)
  import Foundation
  import IOKit.pwr_mgt

  /// Keeps the host's displays awake while a session is live. Display sleep stops
  /// every ScreenCaptureKit stream, virtual displays included, so a host that
  /// wants to keep serving must hold this — as Apple's own Screen Sharing does.
  final class RigDisplaySleepAssertion {
    private var id: IOPMAssertionID = 0
    let created: Bool

    init(reason: String) {
      var id: IOPMAssertionID = 0
      let status = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
        reason as CFString, &id)
      created = status == kIOReturnSuccess
      self.id = id
    }

    deinit { if created { IOPMAssertionRelease(id) } }
  }
#endif
