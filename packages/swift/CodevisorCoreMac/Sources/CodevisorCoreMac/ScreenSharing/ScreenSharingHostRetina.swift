import CoreGraphics

enum ScreenSharingHostRetina {
  struct SharedDisplay: Equatable, Sendable {
    var width: Int
    var height: Int
    var pixelScale: Double
    var isHeadless: Bool
  }

  static func virtualDisplaySize(
    dynamic requested: (width: Int, height: Int)?, shared: SharedDisplay, virtualDisplaysAvailable: Bool
  ) -> (width: Int, height: Int)? {
    if let requested { return ScreenSharingHostVirtualDisplay.clamp(width: requested.width, height: requested.height) }
    guard virtualDisplaysAvailable, shared.isHeadless, shared.pixelScale < 2 else { return nil }
    let points = (width: shared.width, height: shared.height)
    guard ScreenSharingHostVirtualDisplay.clamp(width: points.width, height: points.height) == points else {
      return nil
    }
    return points
  }
}

extension ScreenSharingHostRetina.SharedDisplay {
  init(display id: CGDirectDisplayID) {
    let mode = CGDisplayCopyDisplayMode(id)
    width = mode?.width ?? 0
    height = mode?.height ?? 0
    pixelScale = mode.map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 1
    isHeadless = ScreenSharingDisplayIdentity(display: id).isHeadlessFramebuffer
  }
}

extension ScreenSharingDisplayIdentity {
  static let headlessFramebuffer = (vendor: UInt32(0x756E_6B6E), model: UInt32(0x7669_7274))

  var isHeadlessFramebuffer: Bool {
    vendor == Self.headlessFramebuffer.vendor && model == Self.headlessFramebuffer.model
  }
}
