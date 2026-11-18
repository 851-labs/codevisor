import CodevisorTestSupport
import CoreGraphics
import ScreenSharingConnection
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("The shape of a desktop preview", .timeLimit(.minutes(1)))
struct ScreenSharingPreviewShapeTests {
  private typealias Shape = ScreenSharingPreviewShape
  private typealias Fixture = ScreenSharingConnectionsFixture
  private nonisolated static let notched = CGSize(width: 3024, height: 1964)

  private nonisolated static let insideTheLimits: [(CGSize, Double)] = [
    (notched, 3024.0 / 1964), (CGSize(width: 2560, height: 1600), 1.6), (CGSize(width: 5120, height: 2880), 16.0 / 9),
    (CGSize(width: 1024, height: 768), 4.0 / 3), (CGSize(width: 3840, height: 1920), 2.0),
    (CGSize(width: 2000, height: 2000), 1.0),
  ]

  @Test("A screen inside the limits gets a card of its own shape, so no strip is left", arguments: insideTheLimits)
  func fitsTheScreen(screen: CGSize, aspect: Double) {
    let shape = Shape(screen: screen)
    #expect(shape.card == aspect && shape.picture == aspect)
  }

  @Test("An ultrawide screen stops the card at twice as wide as tall, and a portrait one at square")
  func stopsAtTheLimits() {
    let ultrawide = Shape(screen: CGSize(width: 5120, height: 1440))
    #expect(ultrawide.card == 2 && ultrawide.picture == 5120.0 / 1440)

    let portrait = Shape(screen: CGSize(width: 1440, height: 2560))
    #expect(portrait.card == 1 && portrait.picture == 0.5625)
  }

  @Test(
    "A machine whose screen was never seen gets a 16:10 card",
    arguments: [nil, CGSize.zero, CGSize(width: 1920, height: 0)])
  func startsAtSixteenByTen(screen: CGSize?) {
    #expect(Shape(screen: screen).card == 1.6 && Shape(screen: screen).picture == 1.6)
  }

  @Test("A preview knows the picture's size from the first frame, and follows it when the display changes shape")
  func followsThePicture() async throws {
    let fixture = Fixture()
    let preview = fixture.surface(.watcher)
    #expect(preview.snapshot.pictureSize == nil)
    preview.show()
    try await fixture.goLive()

    await awaitObserved { preview.snapshot.connection == .live }
    #expect(preview.snapshot.pictureSize == CGSize(width: 2, height: 2), "known by the time the picture shows")

    let video = try #require(fixture.fake(for: preview))
    video.onVideoSizeChanged?(Self.notched)
    await awaitObserved { preview.snapshot.pictureSize == Self.notched }
    #expect(fixture.preferences.pictureSize(machineId: Fixture.machineId) == Self.notched)
  }

  @Test("A machine seen before starts in the shape its picture last had, before anything connects")
  func startsInTheLastShape() {
    let fixture = Fixture()
    fixture.preferences.setPictureSize(Self.notched, machineId: Fixture.machineId)

    let preview = fixture.surface(.watcher)

    #expect(preview.snapshot.connection == .off && preview.snapshot.pictureSize == Self.notched)
  }
}
