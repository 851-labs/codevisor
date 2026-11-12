import AppKit
import CGVirtualDisplayPrivate
import ScreenSharing

@MainActor
final class ScreenSharingHostVirtualDisplay {
  nonisolated static let vendorID: UInt32 = 0xC0DF
  static let name = "Codevisor Screen Sharing"
  nonisolated static let maximum = (width: 1920, height: 1080)
  nonisolated static let minimum = (width: 800, height: 600)

  static var isAvailable: Bool {
    ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
      .allSatisfy { NSClassFromString($0) != nil }
  }

  nonisolated static func clamp(width: Int, height: Int) -> (width: Int, height: Int) {
    let width = Double(max(1, width)), height = Double(max(1, height))
    let grown = max(1, Double(minimum.width) / width, Double(minimum.height) / height)
    let scale = grown * min(1, Double(maximum.width) / (width * grown), Double(maximum.height) / (height * grown))
    func fit(_ value: Double, _ lower: Int, _ upper: Int) -> Int {
      min(upper, max(lower, Int((value * scale).rounded()))) / 2 * 2
    }
    return (fit(width, minimum.width, maximum.width), fit(height, minimum.height, maximum.height))
  }

  private let display: CGVirtualDisplay
  let displayID: CGDirectDisplayID
  private(set) var size: (width: Int, height: Int)
  let shared: CGDirectDisplayID
  private let mirrors: Bool
  private(set) var replacesShared = false
  private let queue = DispatchQueue(label: "codevisor.screen-sharing.virtual-display")

  init(width: Int, height: Int, standingInFor shared: CGDirectDisplayID, mirrors: Bool) throws {
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
    self.shared = shared
    self.mirrors = mirrors
    let size = Self.clamp(width: width, height: height)
    self.size = size
    try apply(size)
  }

  func show() async throws {
    for _ in 0..<60 where CGDisplayIsOnline(displayID) == 0 || CGDisplayPixelsWide(displayID) == 0 {
      try await Task.sleep(for: .milliseconds(50))
    }
    guard CGDisplayIsOnline(displayID) != 0 else {
      throw ScreenSharingError.unavailable("The virtual display didn't come online.")
    }
    try await selectHiDPIMode()
    if !mirrors, try await replacedShared() {
      replacesShared = true
      return
    }
    try Self.configure("Mirroring the display") { CGConfigureDisplayMirrorOfDisplay($0, shared, displayID) }
  }

  private func replacedShared() async throws -> Bool {
    for _ in 0..<60 where ScreenSharingDisplayIdentity.isOnline(shared) {
      try await Task.sleep(for: .milliseconds(50))
    }
    return !ScreenSharingDisplayIdentity.isOnline(shared)
  }

  func selectHiDPIMode() async throws {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    for _ in 0..<100 {
      let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
      if let mode = modes.first(where: {
        $0.width == size.width && $0.height == size.height && $0.pixelWidth == size.width * 2
      }) {
        if showsHiDPIMode { return }
        try Self.configure("Switching the virtual display to \(size.width)×\(size.height) pt") {
          CGConfigureDisplayWithDisplayMode($0, displayID, mode, nil)
        }
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ScreenSharingError.unavailable("The virtual display has no \(size.width)×\(size.height) pt HiDPI mode.")
  }

  var showsHiDPIMode: Bool {
    guard let current = CGDisplayCopyDisplayMode(displayID) else { return false }
    return current.width == size.width && current.height == size.height && current.pixelWidth == size.width * 2
  }

  func resize(width: Int, height: Int) async throws {
    let size = Self.clamp(width: width, height: height)
    guard size != self.size else { return }
    let previous = self.size
    do {
      try apply(size)
      self.size = size
      try await selectHiDPIMode()
    } catch {
      self.size = previous
      try? apply(previous)
      try? await selectHiDPIMode()
      guard showsHiDPIMode else { throw error }
      throw KeptSize(size: previous, reason: error.localizedDescription)
    }
  }

  struct KeptSize: Error {
    let size: (width: Int, height: Int)
    let reason: String
  }

  func release() {
    guard ScreenSharingDisplayIdentity.isOnline(shared), CGDisplayIsInMirrorSet(shared) != 0 else { return }
    try? Self.configure("Unmirroring the display") {
      CGConfigureDisplayMirrorOfDisplay($0, self.shared, kCGNullDirectDisplay)
    }
  }

  private func apply(_ size: (width: Int, height: Int)) throws {
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    settings.modes = [CGVirtualDisplayMode(width: UInt(size.width), height: UInt(size.height), refreshRate: 60)]
    guard display.apply(settings) else {
      throw ScreenSharingError.unavailable("The virtual display refused \(size.width)×\(size.height).")
    }
  }

  private static func configure(_ what: String, _ change: (CGDisplayConfigRef?) -> CGError) throws {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else {
      throw ScreenSharingError.unavailable("This Mac's displays can't be configured now.")
    }
    let result = change(config)
    guard result == .success else {
      CGCancelDisplayConfiguration(config)
      throw ScreenSharingError.unavailable("\(what) failed (\(result.rawValue)).")
    }
    let completed = CGCompleteDisplayConfiguration(config, .forSession)
    guard completed == .success else {
      throw ScreenSharingError.unavailable("\(what) failed (\(completed.rawValue)).")
    }
  }
}
