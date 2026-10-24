import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

let notificationCenterBundle = "com.apple.notificationcenterui"
let wallpaperTitle = "Wallpaper"
let dockBundle = "com.apple.dock"
let cornerSize = CGSize(width: 440, height: 320)
let margin: CGFloat = 36
let bannerDifference = 24

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: bento-notifications-capture <output directory>\n".utf8))
  exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let display = content.displays.first(where: { CGDisplayIsMain($0.displayID) != 0 }) else {
  throw CocoaError(.featureUnsupported)
}
let scale = NSScreen.main?.backingScaleFactor ?? 2
let menuBarHeight = NSScreen.main.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
let corner = CGRect(
  x: display.frame.maxX - cornerSize.width, y: display.frame.minY + menuBarHeight, width: cornerSize.width,
  height: cornerSize.height)

guard let wallpaper = content.windows.first(where: { $0.title == wallpaperTitle && $0.frame.contains(corner) }),
  content.windows.contains(where: {
    $0.owningApplication?.bundleIdentifier == notificationCenterBundle && $0.frame.intersects(corner)
  })
else {
  FileHandle.standardError.write(Data("No wallpaper or notification banners in the top-right corner\n".utf8))
  exit(1)
}
let foreign = content.windows.filter { window in
  window.isOnScreen && window.windowLayer >= 0 && window.frame.intersects(corner)
    && ![notificationCenterBundle, dockBundle].contains(window.owningApplication?.bundleIdentifier)
}
guard foreign.isEmpty else {
  for window in foreign {
    let owner = window.owningApplication?.applicationName ?? "?"
    print("in the way:", owner, window.title ?? "", window.frame, "layer", window.windowLayer)
  }
  exit(1)
}

func capture(_ filter: SCContentFilter) async throws -> CGImage {
  let configuration = SCStreamConfiguration()
  configuration.sourceRect = corner.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
  configuration.width = Int(corner.width * scale)
  configuration.height = Int(corner.height * scale)
  configuration.showsCursor = false
  configuration.captureResolution = .best
  return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
}

func pixels(of image: CGImage) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
  bytes.withUnsafeMutableBytes { buffer in
    CGContext(
      data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
      .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
  return bytes
}

func bannerBounds(desktop: CGImage, wallpaperOnly: CGImage) -> CGRect? {
  let withBanners = pixels(of: desktop)
  let bare = pixels(of: wallpaperOnly)
  var bounds: CGRect?
  for y in 0..<desktop.height {
    for x in 0..<desktop.width {
      let index = (y * desktop.width + x) * 4
      let differs = (0..<3).contains { abs(Int(withBanners[index + $0]) - Int(bare[index + $0])) > bannerDifference }
      if differs {
        bounds = (bounds ?? CGRect(x: x, y: y, width: 1, height: 1)).union(CGRect(x: x, y: y, width: 1, height: 1))
      }
    }
  }
  return bounds
}

let desktop = try await capture(SCContentFilter(display: display, excludingWindows: []))
let wallpaperOnly = try await capture(SCContentFilter(display: display, including: [wallpaper]))
guard let banners = bannerBounds(desktop: desktop, wallpaperOnly: wallpaperOnly) else {
  FileHandle.standardError.write(Data("The banners were not visible in the top-right corner\n".utf8))
  exit(1)
}
let crop = banners.insetBy(dx: -margin * scale, dy: -margin * scale)
  .intersection(CGRect(x: 0, y: 0, width: desktop.width, height: desktop.height))
guard let image = desktop.cropping(to: crop) else { throw CocoaError(.fileWriteUnknown) }

let appearance = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? "dark" : "light"
let file = outputDirectory.appendingPathComponent("notifications-\(appearance)@2x.png")
guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
else { throw CocoaError(.fileWriteUnknown) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
print(file.path, image.width, image.height)
