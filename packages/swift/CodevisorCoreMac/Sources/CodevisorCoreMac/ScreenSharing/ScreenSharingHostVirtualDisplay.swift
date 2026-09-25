import AppKit
import CGVirtualDisplayPrivate
import ScreenSharing

/// The host's display sized to the viewer (851-2376): a HiDPI virtual display of the viewer's
/// pane size in points, with the shared physical display mirrored onto it. The physical display
/// then shows the same desktop at the viewer's size (what Apple's High Performance mode does), and
/// capture takes the virtual display pixel for pixel. Releasing this object removes the display,
/// which dissolves the mirror, so a crash can't leave the host's display changed.
///
/// Measured on tuftlord with `screen-sharing-rig mirror-check`: mirroring a 1512×982-point display
/// onto a 1280×800 virtual display gave both 1280×800 points (2560×1600 pixels), and undoing it
/// restored 1512×982.
@MainActor
final class ScreenSharingHostVirtualDisplay {
  static let vendorID: UInt32 = 0xC0DF
  static let name = "Codevisor Screen Sharing"
  /// Points; the raster is twice that, up to 3840×2400 pixels (the encoder's 4K budget).
  static let maximum = (width: 1920, height: 1200)
  static let minimum = (width: 640, height: 400)

  static var isAvailable: Bool {
    ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
      .allSatisfy { NSClassFromString($0) != nil }
  }

  /// `width`×`height` clamped to what the display supports, rounded to even points.
  static func clamp(width: Int, height: Int) -> (width: Int, height: Int) {
    (
      min(maximum.width, max(minimum.width, width)) / 2 * 2,
      min(maximum.height, max(minimum.height, height)) / 2 * 2
    )
  }

  private let display: CGVirtualDisplay
  let displayID: CGDirectDisplayID
  private(set) var size: (width: Int, height: Int)
  private let mirrored: CGDirectDisplayID
  private let queue = DispatchQueue(label: "codevisor.screen-sharing.virtual-display")

  /// Creates the display at `width`×`height` points; `mirror()` then puts `physical` on it.
  init(width: Int, height: Int, mirroring physical: CGDirectDisplayID) throws {
    guard Self.isAvailable else { throw ScreenSharingError.unavailable("This Mac can't create a virtual display.") }
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.queue = queue
    descriptor.name = Self.name
    descriptor.vendorID = Self.vendorID
    descriptor.productID = 1
    descriptor.serialNum = 1
    descriptor.maxPixelsWide = UInt32(Self.maximum.width * 2)
    descriptor.maxPixelsHigh = UInt32(Self.maximum.height * 2)
    // ~110 points per inch, the density of Apple's 27-inch panels.
    let millimetersPerPoint = 25.4 / 110.0
    descriptor.sizeInMillimeters = CGSize(
      width: Double(Self.maximum.width) * millimetersPerPoint, height: Double(Self.maximum.height) * millimetersPerPoint
    )
    descriptor.terminationHandler = { _, _ in }
    display = CGVirtualDisplay(descriptor: descriptor)
    displayID = display.displayID
    mirrored = physical
    let size = Self.clamp(width: width, height: height)
    self.size = size
    try apply(size)
  }

  /// Mirrors the physical display onto this one once WindowServer has it online: mirroring a
  /// display that isn't online yet fails (it did in the app on tuftlord, 851-2376).
  func mirror() async throws {
    for _ in 0..<60 where CGDisplayIsOnline(displayID) == 0 || CGDisplayPixelsWide(displayID) == 0 {
      try await Task.sleep(for: .milliseconds(50))
    }
    guard CGDisplayIsOnline(displayID) != 0 else {
      throw ScreenSharingError.unavailable("The virtual display didn't come online.")
    }
    try Self.configure { CGConfigureDisplayMirrorOfDisplay($0, mirrored, displayID) }
  }

  /// Resizes the display (and so the mirrored physical one) to `width`×`height` points.
  func resize(width: Int, height: Int) throws {
    let size = Self.clamp(width: width, height: height)
    guard size != self.size else { return }
    try apply(size)
    self.size = size
  }

  /// Gives the physical display its own mode back; the display itself goes when this object does.
  func release() {
    try? Self.configure { CGConfigureDisplayMirrorOfDisplay($0, self.mirrored, kCGNullDirectDisplay) }
  }

  private func apply(_ size: (width: Int, height: Int)) throws {
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    settings.modes = [CGVirtualDisplayMode(width: UInt(size.width), height: UInt(size.height), refreshRate: 60)]
    guard display.apply(settings) else {
      throw ScreenSharingError.unavailable("The virtual display refused \(size.width)×\(size.height).")
    }
  }

  private static func configure(_ change: (CGDisplayConfigRef?) -> CGError) throws {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else {
      throw ScreenSharingError.unavailable("This Mac's displays can't be configured now.")
    }
    let result = change(config)
    guard result == .success else {
      CGCancelDisplayConfiguration(config)
      throw ScreenSharingError.unavailable("Mirroring the display failed (\(result.rawValue)).")
    }
    guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
      throw ScreenSharingError.unavailable("Mirroring the display failed.")
    }
  }
}
