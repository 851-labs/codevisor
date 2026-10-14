import ColorSync
import CoreGraphics

struct ScreenSharingDisplayIdentity: Equatable, Sendable {
  struct Online: Equatable, Sendable {
    let id: CGDirectDisplayID
    let identity: ScreenSharingDisplayIdentity
    let isMain: Bool
    let isVirtual: Bool
  }

  let vendor: UInt32
  let model: UInt32
  let serial: UInt32

  static func follow(
    _ id: CGDirectDisplayID, identity: ScreenSharingDisplayIdentity, online: [Online]
  ) -> CGDirectDisplayID? {
    if online.contains(where: { $0.id == id }) { return id }
    let physical = online.filter { !$0.isVirtual }
    let matching = physical.filter { $0.identity == identity }
    if matching.count == 1 { return matching[0].id }
    let candidates = matching.isEmpty ? physical : matching
    if candidates.count == 1 { return candidates[0].id }
    return candidates.first(where: \.isMain)?.id
  }
}

extension ScreenSharingDisplayIdentity {
  static func sessionSurvives(
    shared: CGDirectDisplayID, identity: ScreenSharingDisplayIdentity, virtual: CGDirectDisplayID?,
    online: [Online]
  ) -> Bool {
    guard follow(shared, identity: identity, online: online) != nil else { return false }
    guard let virtual else { return true }
    return online.contains { $0.id == virtual }
  }

  init(display id: CGDirectDisplayID) {
    self.init(
      vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
  }

  static func isOnThisMac(_ displayId: String) -> Bool {
    online().contains { display in
      guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue() else { return false }
      return CFUUIDCreateString(nil, uuid) as String == displayId
    }
  }

  static func online() -> [Online] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
    let main = CGMainDisplayID()
    return ids.prefix(Int(count)).map { id in
      Online(
        id: id, identity: ScreenSharingDisplayIdentity(display: id), isMain: id == main,
        isVirtual: CGDisplayVendorNumber(id) == ScreenSharingHostVirtualDisplay.vendorID)
    }
  }
}
