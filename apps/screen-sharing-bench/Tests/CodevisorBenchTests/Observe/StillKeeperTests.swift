import CoreVideo
import Foundation
import ScreenSharingBench
import Testing

@testable import CodevisorBench

@MainActor
struct StillKeeperTests {
  @Test func keepsTheLastFrameOfAWantedVersionWithinTwoSecondsOfItsFirst() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "stills-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let keeper = try StillKeeper(StillsOptions(directory: directory.path, versions: [4]))

    keeper.offer(try Self.frame(gray: 10), version: 3, ptsNs: 0)
    keeper.offer(try Self.frame(gray: 20), version: 4, ptsNs: 1_000_000_000)
    keeper.offer(try Self.frame(gray: 30), version: 4, ptsNs: 2_900_000_000)
    keeper.offer(try Self.frame(gray: 40), version: 4, ptsNs: 3_100_000_000)
    keeper.offer(try Self.frame(gray: 50), version: 5, ptsNs: 4_000_000_000)
    try await keeper.finish()

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names == ["4.png"])
    #expect(try StillImage.read(directory.appending(path: "4.png")).pixel(x: 1, y: 1).red == 30)
  }

  private static func frame(gray: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
    let frame = try #require(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    defer { CVPixelBufferUnlockBaseAddress(frame, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(frame))
    memset(base, Int32(gray), CVPixelBufferGetBytesPerRow(frame) * 4)
    return frame
  }
}
