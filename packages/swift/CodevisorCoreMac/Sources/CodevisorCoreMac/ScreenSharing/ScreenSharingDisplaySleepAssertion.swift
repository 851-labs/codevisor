import Foundation
import IOKit.pwr_mgt

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
