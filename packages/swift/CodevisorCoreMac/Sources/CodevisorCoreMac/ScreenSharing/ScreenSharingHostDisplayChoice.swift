import CodevisorClient
import CoreGraphics

struct ScreenSharingHostDisplayChoice {
  typealias Display = (id: UInt32, description: ServerScreenSharingDisplay)
  private var lastShared: [String: String] = [:]

  func display(
    for owner: ScreenSharingHostLease.Owner, asking displayId: String?, among available: [Display]
  ) -> Display? {
    let asked = available.first { $0.description.id == displayId }
    guard let appKey = owner.appKey else { return asked }

    let last = available.first { $0.description.id == lastShared[appKey] }
    return asked ?? last ?? available.first { $0.id == CGMainDisplayID() } ?? available.first
  }

  mutating func remember(_ display: Display, for owner: ScreenSharingHostLease.Owner) {
    guard let appKey = owner.appKey else { return }

    lastShared[appKey] = display.description.id
  }
}
