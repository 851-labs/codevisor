import ScreenSharingBench
import Testing

struct BenchRegistrationTests {
  private static let geometry = BenchFidelityImages.geometry

  @Test func theCardItselfRegistersAtTheOrigin() {
    #expect(Self.register(BenchFidelityImages.textCard()) == .registered(.zero))
  }

  @Test func aCardShownInALargerCaptureRegistersAtItsOffset() {
    let offset = BenchPixelOffset(dx: 7, dy: 5)
    let capture = BenchFidelityImages.placed(BenchFidelityImages.textCard(), width: 180, height: 110, at: offset)

    #expect(Self.register(capture) == .registered(offset))
  }

  @Test func aFarOffsetIsFoundCoarseToFine() {
    let offset = BenchPixelOffset(dx: 123, dy: 77)
    let capture = BenchFidelityImages.placed(BenchFidelityImages.chromaCard(), width: 400, height: 300, at: offset)

    #expect(Self.register(capture) == .registered(offset))
  }

  @Test func aHalfSizeCaptureIsNotOneToOne() {
    let capture = BenchFidelityImages.halved(BenchFidelityImages.textCard())

    #expect(Self.register(capture) == .notOneToOne("the 80x48 capture is smaller than the 160x96 card"))
  }

  @Test func aHalfSizeCardInsideALargerCaptureIsNotOneToOne() {
    let capture = BenchFidelityImages.placed(
      BenchFidelityImages.halved(BenchFidelityImages.textCard()), width: 200, height: 120, at: .zero)

    guard case .notOneToOne = Self.register(capture) else {
      Issue.record("a half-size card registered")
      return
    }
  }

  private static func register(_ image: BenchRGBImage) -> BenchRegistration.Outcome {
    BenchRegistration.register(BenchLumaImage(BenchYCbCrPlanes(image)), geometry: geometry)
  }
}
