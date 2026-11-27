import CoreGraphics
import Foundation
import Metal
@preconcurrency import RiveRuntime

@MainActor
enum BotMascotStillRenderer {
  enum Failure: Error {
    case noMetal
    case skipped
  }

  static func render(_ still: BotMascotStill) async throws -> CGImage {
    let artwork = BotMascotArtwork.shared
    let look = try await artwork.colorTable().drawable(still.mascot)
    let rig = try await BotMascotRig.make(
      file: try await artwork.riveFile(), values: try await artwork.values(for: look))
    rig.show(still.pose)
    rig.settle(for: BotMascotStage.settleSeconds, step: BotMascotStage.frame)
    let frame = BotMascotFraming.box(for: still.framing, wearingHat: look.hat != BotMascotColorTable.none)
    return try await draw(rig, cropTo: frame)
  }

  private static func draw(_ rig: BotMascotRig, cropTo box: CGRect) async throws -> CGImage {
    guard let device = BotMascotPainter.device else { throw Failure.noMetal }

    let side = Int((CGFloat(BotMascotStill.pixels) * BotMascotFraming.artboardSide / box.width).rounded(.up))
    let target = try BotMascotStillTarget(side: side, device: device)
    let renderer = rig.rive.makeRenderer()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      renderer.draw(
        rig.configuration(drawableSize: CGSize(width: side, height: side)),
        to: target.texture,
        from: device,
        onDraw: target.copying { continuation.resume() },
        onSkipped: { continuation.resume(throwing: Failure.skipped) },
        onError: { continuation.resume(throwing: $0) })
    }
    withExtendedLifetime((rig, renderer)) {}
    return try target.image(cropTo: scaled(box, toSide: side))
  }

  private static func scaled(_ box: CGRect, toSide side: Int) -> CGRect {
    let scale = CGFloat(side) / BotMascotFraming.artboardSide
    return box.applying(CGAffineTransform(scaleX: scale, y: scale))
  }
}
