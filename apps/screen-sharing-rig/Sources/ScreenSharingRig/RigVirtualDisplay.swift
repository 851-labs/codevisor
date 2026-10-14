#if os(macOS)
  import AppKit
  import CGVirtualDisplayPrivate
  import ScreenSharing
  import Foundation

  @MainActor
  final class RigVirtualDisplay {
    static let vendorID: UInt32 = 0xC0DE
    static let name = "Codevisor Rig Display"

    let display: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let framesPerSecond: Int
    private let queue = DispatchQueue(label: "codevisor.rig.virtual-display")

    init(width: Int, height: Int, framesPerSecond: Int, onTermination: @escaping @Sendable () -> Void) throws {
      guard NSClassFromString("CGVirtualDisplay") != nil, NSClassFromString("CGVirtualDisplayDescriptor") != nil,
        NSClassFromString("CGVirtualDisplaySettings") != nil, NSClassFromString("CGVirtualDisplayMode") != nil
      else {
        throw ScreenSharingError.unavailable("CGVirtualDisplay is not available on this macOS build.")
      }
      let descriptor = CGVirtualDisplayDescriptor()
      descriptor.queue = queue
      descriptor.name = Self.name
      descriptor.vendorID = Self.vendorID
      descriptor.productID = UInt32(min(width / 8, 0xFF) << 8 | min(height / 8, 0xFF))
      descriptor.serialNum = 1
      descriptor.maxPixelsWide = UInt32(width * 2)
      descriptor.maxPixelsHigh = UInt32(height * 2)
      let millimetersPerPoint = 25.4 / 110.0
      descriptor.sizeInMillimeters = CGSize(
        width: Double(width) * millimetersPerPoint, height: Double(height) * millimetersPerPoint)
      descriptor.terminationHandler = { _, _ in onTermination() }
      let display = CGVirtualDisplay(descriptor: descriptor)
      let settings = CGVirtualDisplaySettings()
      settings.hiDPI = 1
      settings.modes = [
        CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: Double(framesPerSecond))
      ]
      guard display.apply(settings) else {
        throw ScreenSharingError.unavailable("CGVirtualDisplay rejected \(width)×\(height)@\(framesPerSecond).")
      }
      self.display = display
      displayID = display.displayID
      self.width = width
      self.height = height
      self.framesPerSecond = framesPerSecond
    }

    var screen: NSScreen? { Self.screen(for: displayID) }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
      NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
      }
    }

    func waitForScreen(timeoutSeconds: Double) async throws -> NSScreen {
      let displayID = displayID
      if Self.screen(for: displayID) == nil {
        try await Self.awaitScreen(displayID: displayID, timeoutSeconds: timeoutSeconds)
      }
      guard let screen = Self.screen(for: displayID) else {
        throw ScreenSharingError.unavailable("The virtual display \(displayID) has no AppKit screen.")
      }
      return screen
    }

    private final class Observer: @unchecked Sendable {
      let token: NSObjectProtocol
      init(_ token: NSObjectProtocol) { self.token = token }
      func cancel() { NotificationCenter.default.removeObserver(token) }
    }

    nonisolated static func awaitScreen(displayID: CGDirectDisplayID, timeoutSeconds: Double) async throws {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          if await hasScreen(displayID) { return }
          for await _ in screenChanges() {
            if await hasScreen(displayID) { return }
          }
          throw ScreenSharingError.unavailable("Screen observation ended before the virtual display appeared.")
        }
        group.addTask {
          try await Task.sleep(for: .seconds(timeoutSeconds))
          throw ScreenSharingError.unavailable("The virtual display did not appear within \(timeoutSeconds) s.")
        }
        try await group.next()
        group.cancelAll()
      }
    }

    nonisolated static func hasScreen(_ displayID: CGDirectDisplayID) async -> Bool {
      await MainActor.run { screen(for: displayID) != nil }
    }

    nonisolated static func screenChanges() -> AsyncStream<Void> {
      AsyncStream<Void> { continuation in
        let observer = Observer(
          NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
          ) { _ in continuation.yield() })
        continuation.onTermination = { _ in observer.cancel() }
      }
    }

    var summary: String {
      let online = CGDisplayIsOnline(displayID) != 0
      let bounds = CGDisplayBounds(displayID)
      let pixels = "\(CGDisplayPixelsWide(displayID))×\(CGDisplayPixelsHigh(displayID))"
      return
        "virtual display \(displayID) \(online ? "online" : "offline") · bounds \(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))×\(Int(bounds.height)) pt · \(pixels) px"
    }
  }
#endif
