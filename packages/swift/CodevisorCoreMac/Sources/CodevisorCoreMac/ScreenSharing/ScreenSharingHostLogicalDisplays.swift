import CodevisorClient
import CoreGraphics

struct ScreenSharingHostLogicalDisplays {
  typealias Display = (id: UInt32, description: ServerScreenSharingDisplay)

  enum Kind: Equatable, Sendable { case real, standIn, hostVirtual }

  struct Shared {
    let description: ServerScreenSharingDisplay
    let capturing: CGDirectDisplayID
    let isStandIn: Bool
  }

  let kind: (CGDirectDisplayID) -> Kind
  private var standInID: String?
  private var seesSeveralStandIns = false

  init(kind: @escaping (CGDirectDisplayID) -> Kind = ScreenSharingHostLogicalDisplays.kind) {
    self.kind = kind
  }

  static func kind(of display: CGDirectDisplayID) -> Kind {
    if CGDisplayVendorNumber(display) == ScreenSharingHostVirtualDisplay.vendorID { return .hostVirtual }
    return ScreenSharingDisplayIdentity(display: display).isHeadlessFramebuffer ? .standIn : .real
  }

  func hasOnlyHostVirtual(_ available: [Display]) -> Bool {
    !available.isEmpty && available.allSatisfy { kind($0.id) == .hostVirtual }
  }

  mutating func list(_ available: [Display], shared: Shared?) -> [Display] {
    if available.count(where: { kind($0.id) == .standIn }) > 1 { seesSeveralStandIns = true }
    let listed = available.compactMap { logical($0, shared: shared) }
    guard let shared, listed.contains(where: { $0.id == shared.capturing && kind($0.id) == .hostVirtual }) else {
      return listed
    }

    let sharedID = identifier(of: shared)
    return listed.filter { $0.id == shared.capturing || $0.description.id != sharedID }
  }

  private mutating func logical(_ display: Display, shared: Shared?) -> Display? {
    switch kind(display.id) {
    case .real: return display
    case .standIn: return (display.id, display.description.identified(as: standIn(display.description.id)))
    case .hostVirtual:
      guard let shared, shared.capturing == display.id else { return nil }

      let description = ServerScreenSharingDisplay(
        id: identifier(of: shared), name: shared.description.name, width: display.description.width,
        height: display.description.height)
      return (display.id, description)
    }
  }

  private mutating func identifier(of shared: Shared) -> String {
    shared.isStandIn ? standIn(shared.description.id) : shared.description.id
  }

  private mutating func standIn(_ seen: String) -> String {
    guard !seesSeveralStandIns else { return seen }
    if let standInID { return standInID }

    standInID = seen
    return seen
  }
}

extension ServerScreenSharingDisplay {
  fileprivate func identified(as id: String) -> ServerScreenSharingDisplay {
    var display = ServerScreenSharingDisplay(id: id, name: name, width: width, height: height)
    display.scales = scales
    display.defaultWidth = defaultWidth
    display.defaultHeight = defaultHeight
    return display
  }
}
