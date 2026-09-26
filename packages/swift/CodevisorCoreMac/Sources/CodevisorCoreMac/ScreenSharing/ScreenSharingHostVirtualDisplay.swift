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
  /// Rendered at 2×, the video's 3840×2160 limit.
  static let maximum = (width: 1920, height: 1080)
  static let minimum = (width: 640, height: 400)

  static var isAvailable: Bool {
    ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
      .allSatisfy { NSClassFromString($0) != nil }
  }

  /// The pane's size scaled down as a whole to fit `maximum`, so the display keeps the pane's
  /// shape (clamping each side on its own made a 1438×1200 display for a tall pane, whose video
  /// the encoder refused, and the stream showed it letterboxed in black). Never below `minimum`;
  /// even points.
  static func clamp(width: Int, height: Int) -> (width: Int, height: Int) {
    let width = Double(max(minimum.width, width)), height = Double(max(minimum.height, height))
    let scale = min(1, Double(maximum.width) / width, Double(maximum.height) / height)
    return (
      max(minimum.width, Int(width * scale)) / 2 * 2,
      max(minimum.height, Int(height * scale)) / 2 * 2
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
    try await selectHiDPIMode()
    try Self.configure { CGConfigureDisplayMirrorOfDisplay($0, mirrored, displayID) }
  }

  /// Puts the display in its 2× mode at `size`. WindowServer remembers a display's last mode by
  /// its identity (always the same for this display) and may bring back a 1× one: on tuftlord it
  /// did, and the viewer got text at half the sharpness (1920×1416 points on 1920×1416 pixels,
  /// 2026-09-25). A new size's modes appear shortly after it's applied, so this waits up to 1 s.
  func selectHiDPIMode() async throws {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    for _ in 0..<100 {
      let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
      if let mode = modes.first(where: {
        $0.width == size.width && $0.height == size.height && $0.pixelWidth == size.width * 2
      }) {
        if let current = CGDisplayCopyDisplayMode(displayID), current.width == mode.width,
          current.pixelWidth == mode.pixelWidth
        {
          return
        }
        try Self.configure { CGConfigureDisplayWithDisplayMode($0, displayID, mode, nil) }
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
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
