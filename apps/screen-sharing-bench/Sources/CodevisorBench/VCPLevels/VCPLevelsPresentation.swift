import AppKit
import CoreVideo
import ScreenSharing

@MainActor
enum VCPLevelsPresentation {
  struct Picture {
    let name: String
    let pixels: CVPixelBuffer
    let expectation: VCPLevelsExpectation
  }

  static func stages(_ pictures: [Picture], on screen: NSScreen) async -> [VCPLevelsStage] {
    var stages: [VCPLevelsStage] = []
    for presentation in V2Presentation.allCases {
      for picture in pictures {
        stages.append(await stage(picture, presentation: presentation, on: screen))
      }
    }
    for space in VCPLevelsLayer.Space.allCases {
      for picture in pictures {
        stages.append(await stage(picture, space: space, on: screen))
      }
    }
    return stages
  }

  private static func stage(
    _ picture: Picture, space: VCPLevelsLayer.Space, on screen: NSScreen
  ) async -> VCPLevelsStage {
    let name = "\(picture.name) drawn by the viewer shader into a CAMetalLayer (\(space.rawValue)), display capture"
    do {
      let layer = try VCPLevelsLayer(space, screen: screen)
      let shown = VCPLevelsWindow(showing: layer.view, on: screen)
      defer { shown.close() }
      try await shown.settle()
      try layer.draw(
        ScreenSharingVideoFrame(pixelBuffer: picture.pixels, timestampNs: 1), scale: screen.backingScaleFactor)
      try await shown.settle()
      return await VCPLevelsCapture.displayStage(name, of: shown, expecting: picture.expectation)
    } catch {
      return VCPLevelsStage(name, failed: error)
    }
  }

  private static func stage(
    _ picture: Picture, presentation: V2Presentation, on screen: NSScreen
  ) async -> VCPLevelsStage {
    let name = "\(picture.name) shown by the viewer (\(presentation.rawValue)), display capture BGRA sRGB"
    do {
      let mailbox = ScreenSharingFrameMailbox()
      mailbox.retainsLatest = true
      let surface = try V2Surface(presentation, mailbox: mailbox, metrics: ScreenSharingMetrics())
      let shown = VCPLevelsWindow(showing: surface.view, on: screen)
      defer {
        surface.stop()
        shown.close()
      }
      mailbox.put(ScreenSharingVideoFrame(pixelBuffer: picture.pixels, timestampNs: 1))
      try await shown.settle()
      let layer = metalLayer(in: surface.view).map(describe) ?? "none"
      return await VCPLevelsCapture.displayStage("\(name), layer \(layer)", of: shown, expecting: picture.expectation)
    } catch {
      return VCPLevelsStage(name, failed: error)
    }
  }

  private static func metalLayer(in view: NSView) -> CAMetalLayer? {
    if let layer = view.layer as? CAMetalLayer { return layer }
    return view.subviews.lazy.compactMap(metalLayer).first
  }

  private static func describe(_ layer: CAMetalLayer) -> String {
    [
      layer.colorspace?.name as String? ?? "untagged", "format \(layer.pixelFormat.rawValue)",
      "EDR \(layer.wantsExtendedDynamicRangeContent)", "range \(layer.preferredDynamicRange.rawValue)",
      "tone \(layer.toneMapMode.rawValue)",
      "drawable \(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))",
      "bounds \(Int(layer.bounds.width))x\(Int(layer.bounds.height))@\(layer.contentsScale)",
      "opaque \(layer.isOpaque)", "filter \(layer.magnificationFilter.rawValue)",
      "gravity \(layer.contentsGravity.rawValue)", "transaction \(layer.presentsWithTransaction)",
    ].joined(separator: ", ")
  }
}
