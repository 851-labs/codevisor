import AppKit
import CGVirtualDisplayPrivate
import ScreenSharingBenchScenes

@MainActor
final class PlayerVirtualDisplay {
  private static let name = "CodevisorBench"
  private static let vendorID: UInt32 = 0xC0DB
  private static let refreshRate = 60.0
  private static let pollInterval = Duration.milliseconds(50)
  private static let pollAttempts = 100
  private static let millimetersPerPoint = 25.4 / 110.0

  private let display: CGVirtualDisplay
  private let resolution: BenchSceneResolution
  private let queue = DispatchQueue(label: "codevisor.bench.virtual-display")

  init(_ resolution: BenchSceneResolution) throws {
    self.resolution = resolution
    display = CGVirtualDisplay(descriptor: Self.descriptor(resolution, queue: queue))
    guard display.apply(Self.settings(resolution)) else {
      throw PlayerError.virtualDisplayUnavailable("The virtual display refused \(resolution.rawValue).")
    }
  }

  var displayID: CGDirectDisplayID { display.displayID }

  func screen() async throws -> NSScreen {
    for _ in 0..<Self.pollAttempts {
      try selectMode()
      if let screen = matchingScreen() { return screen }

      try await Task.sleep(for: Self.pollInterval)
    }
    throw PlayerError.virtualDisplayUnavailable(
      "The \(resolution.rawValue) virtual display didn't come online. Its modes: \(availableModes())")
  }

  private func matchingScreen() -> NSScreen? {
    NSScreen.screens.first { screen in
      Self.displayID(of: screen) == displayID && Int(screen.frame.width) == resolution.pointWidth
        && Int(screen.backingScaleFactor) == resolution.scale
    }
  }

  private func selectMode() throws {
    guard CGDisplayIsOnline(displayID) != 0, let mode = wantedMode() else { return }
    guard !Self.same(CGDisplayCopyDisplayMode(displayID), mode) else { return }

    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    guard CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) == .success else {
      CGCancelDisplayConfiguration(config)
      return
    }
    guard CGCompleteDisplayConfiguration(config, .forAppOnly) == .success else {
      throw PlayerError.virtualDisplayUnavailable("Selecting the \(resolution.rawValue) mode failed.")
    }
  }

  private func availableModes() -> String {
    let current = CGDisplayCopyDisplayMode(displayID).map(Self.label) ?? "none"
    return "current \(current); offered " + modes().map(Self.label).joined(separator: ", ")
  }

  private func modes() -> [CGDisplayMode] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
  }

  private static func same(_ current: CGDisplayMode?, _ wanted: CGDisplayMode) -> Bool {
    current?.width == wanted.width && current?.pixelWidth == wanted.pixelWidth
  }

  private static func label(_ mode: CGDisplayMode) -> String {
    "\(mode.width)×\(mode.height) pt (\(mode.pixelWidth) px)"
  }

  private func wantedMode() -> CGDisplayMode? {
    modes().first {
      $0.width == resolution.pointWidth && $0.pixelWidth == resolution.pointWidth * resolution.scale
    }
  }

  private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }

  private static func descriptor(_ resolution: BenchSceneResolution, queue: DispatchQueue) -> CGVirtualDisplayDescriptor
  {
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.queue = queue
    descriptor.name = name
    descriptor.vendorID = vendorID
    descriptor.productID = UInt32(resolution.pointWidth)
    descriptor.serialNum = UInt32(resolution.scale)
    descriptor.maxPixelsWide = UInt32(resolution.pointWidth * resolution.scale)
    descriptor.maxPixelsHigh = UInt32(resolution.pointHeight * resolution.scale)
    descriptor.sizeInMillimeters = CGSize(
      width: Double(resolution.pointWidth) * millimetersPerPoint,
      height: Double(resolution.pointHeight) * millimetersPerPoint)
    descriptor.terminationHandler = { _, _ in }
    return descriptor
  }

  private static func settings(_ resolution: BenchSceneResolution) -> CGVirtualDisplaySettings {
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = resolution.scale > 1 ? 1 : 0
    settings.modes = [
      CGVirtualDisplayMode(
        width: UInt(resolution.pointWidth), height: UInt(resolution.pointHeight), refreshRate: refreshRate)
    ]
    return settings
  }
}
