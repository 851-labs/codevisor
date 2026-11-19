import ColorSync
import CoreGraphics

struct ScreenSharingDisplayIdentity: Equatable, Sendable {
  struct Pixels: Equatable, Sendable {
    let width: Int
    let height: Int
  }

  struct Online: Equatable, Sendable {
    let id: CGDirectDisplayID
    let identity: ScreenSharingDisplayIdentity
    let isMain: Bool
    let isVirtual: Bool
    var pixels: Pixels?

    func isTheSameDisplay(as identity: ScreenSharingDisplayIdentity, pixels shared: Pixels?) -> Bool {
      guard self.identity == identity else { return false }
      guard !identity.isHeadlessFramebuffer, let shared, let pixels else { return true }

      return pixels == shared
    }
  }

  let vendor: UInt32
  let model: UInt32
  let serial: UInt32

  enum Successor: Equatable, Sendable {
    case unchanged
    case renumbered(CGDirectDisplayID)
    case another(CGDirectDisplayID)
    case none
  }

  static func successor(
    of id: CGDirectDisplayID, identity: ScreenSharingDisplayIdentity, pixels: Pixels? = nil, online: [Online]
  ) -> Successor {
    if online.contains(where: { $0.id == id }) { return .unchanged }
    let physical = online.filter { !$0.isVirtual }
    let alike = physical.filter { $0.identity == identity }
    let same = alike.filter { $0.isTheSameDisplay(as: identity, pixels: pixels) }
    if let renumbered = onlyOrMain(same) { return .renumbered(renumbered) }
    guard same.isEmpty, let other = onlyOrMain(alike) ?? onlyOrMain(physical) else { return .none }

    return .another(other)
  }

  static func follow(
    _ id: CGDirectDisplayID, identity: ScreenSharingDisplayIdentity, online: [Online]
  ) -> CGDirectDisplayID? {
    switch successor(of: id, identity: identity, online: online) {
    case .unchanged: id
    case .renumbered(let next), .another(let next): next
    case .none: nil
    }
  }

  private static func onlyOrMain(_ displays: [Online]) -> CGDirectDisplayID? {
    if displays.count == 1 { return displays[0].id }
    return displays.first(where: \.isMain)?.id
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

  static func isOnline(_ id: CGDirectDisplayID) -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
    return ids.prefix(Int(count)).contains(id)
  }

  static func online() -> [Online] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
    let main = CGMainDisplayID()
    return ids.prefix(Int(count)).map { id in
      Online(
        id: id, identity: ScreenSharingDisplayIdentity(display: id), isMain: id == main,
        isVirtual: CGDisplayVendorNumber(id) == ScreenSharingHostVirtualDisplay.vendorID,
        pixels: CGDisplayCopyDisplayMode(id).map { Pixels(width: $0.pixelWidth, height: $0.pixelHeight) })
    }
  }
}
