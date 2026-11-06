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
    return stages
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
      return await VCPLevelsCapture.displayStage(name, of: shown, expecting: picture.expectation)
    } catch {
      return VCPLevelsStage(name, failed: error)
    }
  }
}
