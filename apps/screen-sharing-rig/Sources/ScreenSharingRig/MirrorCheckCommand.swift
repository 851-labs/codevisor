#if os(macOS)
  import CoreGraphics
  import Foundation
  import ImageIO
  import ScreenCaptureKit
  import UniformTypeIdentifiers

  /// `screen-sharing-rig mirror-check WIDTH HEIGHT [--png PATH]` (851-2376): the experiment
  /// behind a virtual display sized to the viewer. Creates a HiDPI virtual display of
  /// WIDTH×HEIGHT points, mirrors the main display onto it, reports what macOS did to both,
  /// optionally saves one frame of the virtual display, then undoes the mirror and releases the
  /// display.
  enum MirrorCheckCommand {
    static func main(arguments: [String]) {
      guard arguments.count >= 2, let width = Int(arguments[0]), let height = Int(arguments[1]) else {
        print("Usage: screen-sharing-rig mirror-check WIDTH HEIGHT [--png PATH]")
        exit(EXIT_FAILURE)
      }
      let png = arguments.firstIndex(of: "--png").flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
      }
      Task { @MainActor in
        do {
          try await run(width: width, height: height, png: png)
          exit(EXIT_SUCCESS)
        } catch {
          print("mirror-check: \(error.localizedDescription)")
          exit(EXIT_FAILURE)
        }
      }
      dispatchMain()
    }

    @MainActor
    static func run(width: Int, height: Int, png: String?) async throws {
      let main = CGMainDisplayID()
      print("before: \(describe(main))")
      let virtual = try RigVirtualDisplay(width: width, height: height, framesPerSecond: 60) {}
      let started = Date()
      while CGDisplayIsOnline(virtual.displayID) == 0 || CGDisplayPixelsWide(virtual.displayID) == 0 {
        guard Date().timeIntervalSince(started) < 5 else { throw CocoaError(.executableLoad) }
        try await Task.sleep(for: .milliseconds(100))
      }
      print("virtual: \(describe(virtual.displayID))")
      try configure { CGConfigureDisplayMirrorOfDisplay($0, main, virtual.displayID) }
      try await Task.sleep(for: .seconds(2))
      print("mirrored main: \(describe(main))")
      print("mirrored virtual: \(describe(virtual.displayID))")
      if let png {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if let display = content.displays.first(where: { $0.displayID == virtual.displayID }) {
          let configuration = SCStreamConfiguration()
          configuration.width = CGDisplayPixelsWide(virtual.displayID) * 2
          configuration.height = CGDisplayPixelsHigh(virtual.displayID) * 2
          let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)
          if let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, UTType.png.identifier as CFString, 1, nil)
          {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("frame: \(image.width)×\(image.height) → \(png)")
          }
        } else {
          print("frame: the virtual display isn't shareable content (mirrored away?)")
        }
      }
      try configure { CGConfigureDisplayMirrorOfDisplay($0, main, kCGNullDirectDisplay) }
      try await Task.sleep(for: .seconds(1))
      withExtendedLifetime(virtual) {}
      print("after unmirror: \(describe(main))")
    }

    static func configure(_ change: (CGDisplayConfigRef?) -> CGError) throws {
      var config: CGDisplayConfigRef?
      guard CGBeginDisplayConfiguration(&config) == .success else { throw CocoaError(.featureUnsupported) }
      let result = change(config)
      guard result == .success else {
        CGCancelDisplayConfiguration(config)
        throw NSError(domain: "CGError", code: Int(result.rawValue))
      }
      let completed = CGCompleteDisplayConfiguration(config, .forSession)
      guard completed == .success else { throw NSError(domain: "CGError", code: Int(completed.rawValue)) }
    }

    static func describe(_ id: CGDirectDisplayID) -> String {
      let bounds = CGDisplayBounds(id)
      let mode = CGDisplayCopyDisplayMode(id)
      let mirrorOf = CGDisplayMirrorsDisplay(id)
      return
        "display \(id): \(Int(bounds.width))×\(Int(bounds.height)) pt at \(Int(bounds.minX)),\(Int(bounds.minY)); mode \(mode.map { "\($0.width)×\($0.height) pt, \($0.pixelWidth)×\($0.pixelHeight) px, \(Int($0.refreshRate)) Hz" } ?? "none"); mirrors \(mirrorOf == kCGNullDirectDisplay ? "nothing" : String(mirrorOf)); in mirror set \(CGDisplayIsInMirrorSet(id) != 0)"
    }
  }
#endif
