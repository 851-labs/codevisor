import CodevisorClient
import CoreGraphics

struct ScreenSharingHostDisplayChoice {
  typealias Display = (id: UInt32, description: ServerScreenSharingDisplay)
  private var lastShared: [String: String] = [:]
  private let isHostVirtual: (CGDirectDisplayID) -> Bool

  init(
    isHostVirtual: @escaping (CGDirectDisplayID) -> Bool = {
      CGDisplayVendorNumber($0) == ScreenSharingHostVirtualDisplay.vendorID
    }
  ) {
    self.isHostVirtual = isHostVirtual
  }

  func display(
    for owner: ScreenSharingHostLease.Owner, asking displayId: String?, among available: [Display]
  ) -> Display? {
    guard let appKey = owner.appKey else { return available.first { $0.description.id == displayId } }

    let shareable = available.filter { !isHostVirtual($0.id) }
    let asked = shareable.first { $0.description.id == displayId }
    let last = shareable.first { $0.description.id == lastShared[appKey] }
    return asked ?? last ?? shareable.first { $0.id == CGMainDisplayID() } ?? shareable.first
  }

  func awaitsRealDisplay(for owner: ScreenSharingHostLease.Owner, among available: [Display]) -> Bool {
    owner.appKey != nil && !available.isEmpty && available.allSatisfy { isHostVirtual($0.id) }
  }

  mutating func remember(_ display: Display, for owner: ScreenSharingHostLease.Owner) {
    guard let appKey = owner.appKey, !isHostVirtual(display.id) else { return }

    lastShared[appKey] = display.description.id
  }
}
