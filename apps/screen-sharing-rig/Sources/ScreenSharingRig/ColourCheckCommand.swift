#if os(macOS)
  import AppKit
  import CoreGraphics
  import ScreenCaptureKit

  /// `screen-sharing-rig colour-check CARD.png` (851-2398): shows the card 1:1 in a window this
  /// process owns, captures that window through ScreenCaptureKit in several colour spaces, and
  /// prints the flat colour patches each one delivers next to the card's own values. Isolates what
  /// capture does to colour from the codec, the network and the viewer.
  enum ColourCheckCommand {
    /// Card-space centres of flat patches in the 851-2381 sharpness card.
    static let patches: [(name: String, x: Int, y: Int)] = [
      ("blue", 1300, 198), ("magenta", 1300, 254), ("red", 1300, 310), ("sky", 1300, 366), ("white", 700, 540),
    ]
    static let spaces: [(name: String, space: String)] = [
      ("itur_709 (product)", CGColorSpace.itur_709 as String), ("sRGB", CGColorSpace.sRGB as String),
      ("displayP3", CGColorSpace.displayP3 as String),
    ]

    static func main(arguments: [String]) {
      guard let path = arguments.first,
        let card = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else {
        print("Usage: screen-sharing-rig colour-check CARD.png")
        exit(EXIT_FAILURE)
      }
      NSApplication.shared.setActivationPolicy(.accessory)
      Task { @MainActor in
        do {
          try await run(card: card)
          exit(EXIT_SUCCESS)
        } catch {
          print("colour-check: \(error.localizedDescription)")
          exit(EXIT_FAILURE)
        }
      }
      NSApplication.shared.run()
    }

    @MainActor
    static func run(card: CGImage) async throws {
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      let size = NSSize(width: CGFloat(card.width) / scale, height: CGFloat(card.height) / scale)
      let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size), styleMask: [.borderless], backing: .buffered,
        defer: false)
      let view = NSView(frame: NSRect(origin: .zero, size: size))
      view.wantsLayer = true
      view.layer?.contents = card
      view.layer?.contentsGravity = .resize
      view.layer?.magnificationFilter = .nearest
      view.layer?.contentsScale = scale
      window.contentView = view
      window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .seconds(1))
      let content = try await SCShareableContent.currentProcess
      guard let owned = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
        throw CocoaError(.fileNoSuchFile)
      }
      print(row("card (sRGB)", values(of: card)))
      for (name, space) in spaces {
        let configuration = SCStreamConfiguration()
        configuration.width = card.width
        configuration.height = card.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = space as CFString
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
          contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: configuration)
        print(row("\(name) → tagged \((image.colorSpace?.name as String?) ?? "none")", values(of: image)))
      }
    }

    /// The image's own stored values (drawn in its own colour space, so nothing is converted).
    static func values(of image: CGImage) -> [(Int, Int, Int)] {
      let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
      guard
        let context = CGContext(
          data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return [] }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
      return patches.map { patch in
        let x = patch.x * image.width / 1400, y = patch.y * image.height / 560
        let pixel = data + (y * image.width + x) * 4
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
      }
    }

    static func row(_ label: String, _ values: [(Int, Int, Int)]) -> String {
      label.padding(toLength: 44, withPad: " ", startingAt: 0)
        + zip(patches, values).map { "\($0.name) \($1.0),\($1.1),\($1.2)" }.joined(separator: "  ")
    }
  }
#endif
