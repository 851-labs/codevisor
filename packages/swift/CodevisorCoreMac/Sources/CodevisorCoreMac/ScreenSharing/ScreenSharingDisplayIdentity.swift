import CoreGraphics

/// Which physical display a session shares, across renumbering. macOS can give a display a new
/// ID when the display set changes: on a Mac Studio with one display, the virtual display
/// appearing and going made display 188 come back as 190 (2026-09-27), and every capture
/// restart then asked for 188 ("Selected display is unavailable") until the session ended.
/// A session follows its display by hardware identity instead of by ID.
struct ScreenSharingDisplayIdentity: Equatable, Sendable {
  struct Online: Equatable, Sendable {
    let id: CGDirectDisplayID
    let identity: ScreenSharingDisplayIdentity
    let isMain: Bool
    /// One of the host's own virtual displays: never the shared display.
    let isVirtual: Bool
  }

  let vendor: UInt32
  let model: UInt32
  let serial: UInt32

  /// The display now standing for `id`: `id` itself while it's online; else the online display
  /// with the same hardware identity; else, when that can't be told apart, the only physical
  /// display or the main one. nil when there's no candidate (the display set is mid-change).
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
  /// Whether a session can go on after the display set changed: the display it shares can still
  /// be followed, and the host's virtual display it mirrors onto, if any, is still online.
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

  /// The displays WindowServer has online right now.
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
