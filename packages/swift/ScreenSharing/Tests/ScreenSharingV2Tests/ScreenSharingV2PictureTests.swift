import CoreVideo
import Foundation
import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2PictureTests {
  private static let update = ScreenSharingTileUpdate(id: 1, tiles: [0])

  @Test func aTileStillDecodingWhenItsEncoderIsReplacedIsNotPlacedOnTheNewPicture() throws {
    var picture = ScreenSharingV2Picture()
    let (old, new) = (try Self.context(encoder: 1), try Self.context(encoder: 2))
    let (oldImage, newImage) = (try Self.image(), try Self.image())
    let followed = [old, new].map { context in
      defer { picture.received(Self.update, tile: 0) }
      return picture.follows(context.meta)
    }

    let afterTheSwitch = picture.resolved(.decoded(old, oldImage), of: old.meta, tile: 0)
    let shown = picture.resolved(.decoded(new, newImage), of: new.meta, tile: 0)?.composite

    #expect(followed == [true, true])
    #expect(afterTheSwitch == nil)
    #expect(try #require(shown).snapshot.images[0] === newImage)
  }

  @Test func aTileThatFailedForAReplacedEncoderDoesNotGiveUpTheNewEncodersTile() throws {
    var picture = ScreenSharingV2Picture()
    let (old, new) = (try Self.context(encoder: 1), try Self.context(encoder: 2))
    let image = try Self.image()
    let followed = [old, new].map { context in
      defer { picture.received(Self.update, tile: 0) }
      return picture.follows(context.meta)
    }

    let afterTheSwitch = picture.resolved(.missing, of: old.meta, tile: 0)
    let shown = picture.resolved(.decoded(new, image), of: new.meta, tile: 0)

    #expect(followed == [true, true])
    #expect(afterTheSwitch == nil)
    #expect(shown?.isLate == false)
    #expect(shown?.composite?.snapshot.images[0] === image)
  }

  private static func image() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
    return try #require(buffer)
  }

  private static func context(encoder: UInt32) throws -> ScreenSharingV2DecodeContext {
    let meta = ScreenSharingV2FrameMeta(
      sourceTimestampNs: 1, clock: 0, captureUs: 0, admissionUs: 0, encodeUs: 0, handOffUs: 0, isRefresh: false,
      update: update, layout: ScreenSharingV2TileLayout(width: 640, height: 384, count: 1),
      encoder: ScreenSharingV2EncoderGeneration(number: encoder))
    let frame = ScreenSharingReceivedFrame(
      stream: 0, frame: 0, isKeyFrame: true, ltrToken: nil, meta: meta.data, payload: ScreenSharingAccessUnit(Data()),
      assemblingUs: 0, recovery: .none)
    return ScreenSharingV2DecodeContext(frame: frame, meta: meta, receivedNs: 0, submittedNs: 0) { _ in }
  }
}
