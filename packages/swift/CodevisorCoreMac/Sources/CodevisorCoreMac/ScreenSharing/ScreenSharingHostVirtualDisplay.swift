import AppKit
import CGVirtualDisplayPrivate
import ScreenSharing

@MainActor
final class ScreenSharingHostVirtualDisplay {
  nonisolated static let vendorID: UInt32 = 0xC0DF
  static let name = "Codevisor Screen Sharing"
  static let maximum = (width: 1920, height: 1080)
  static let minimum = (width: 640, height: 400)

  static var isAvailable: Bool {
    ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
      .allSatisfy { NSClassFromString($0) != nil }
  }

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

  func resize(width: Int, height: Int) throws {
    let size = Self.clamp(width: width, height: height)
    guard size != self.size else { return }
    try apply(size)
    self.size = size
  }

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
