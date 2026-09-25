import Foundation
import IOKit.pwr_mgt

/// Keeps the host's displays awake while a session is live (851-2375). Display
/// sleep stops every ScreenCaptureKit stream and none resumes on wake, so a host
/// left alone would go dark mid-session; Apple's Screen Sharing holds the same
/// assertion. It only removes idle sleep: an explicit sleep, a closed lid or a
/// lock still stops the displays. Released when the object goes.
public final class ScreenSharingDisplaySleepAssertion {
  private let id: IOPMAssertionID
  public let created: Bool

  public init(reason: String) {
    var id: IOPMAssertionID = 0
    let status = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason as CFString, &id)
    created = status == kIOReturnSuccess
    self.id = id
  }

  deinit { if created { IOPMAssertionRelease(id) } }
}
