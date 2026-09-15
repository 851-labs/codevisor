import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use video files", .timeLimit(.minutes(1)))
struct ComputerUseVideoWriterTests {
  @Test("A static screen remains visible for the full recording duration in the MP4")
  func staticDuration() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let completed = AsyncThrowingStream<Double, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let started = AsyncThrowingStream<Bool, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let writer = try ComputerUseVideoWriter(
      url: url, size: CGSize(width: 640, height: 480), fps: 30,
      onStarted: {
        started.continuation.yield(true); started.continuation.finish()
      },
      onFinished: {
        completed.continuation.yield($0); completed.continuation.finish()
      },
      onError: {
        started.continuation.finish(throwing: $0); completed.continuation.finish(throwing: $0)
      })
    defer { writer.cancel(); writer.queue.sync {} }
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let frame = try #require(pixel)
    CVPixelBufferLockBaseAddress(frame, [])
    memset(CVPixelBufferGetBaseAddress(frame), 128, CVPixelBufferGetDataSize(frame))
    CVPixelBufferUnlockBaseAddress(frame, [])
    writer.queue.sync { writer.append(frame, at: CMTime(seconds: 100, preferredTimescale: 600)) }
    #expect(try await started.stream.first(where: { _ in true }) == true)
    writer.finish(duration: 3)
    #expect(try #require(try await completed.stream.first(where: { _ in true })) >= 3)
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    #expect(abs(CMTimeGetSeconds(duration) - 3) < 0.1)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 640, height: 480))
    let generator = AVAssetImageGenerator(asset: asset)
    let ending = try await generator.image(at: CMTime(seconds: 2.9, preferredTimescale: 600))
    #expect(ending.image.width == 640)
  }

  @Test("A recording with no captured frames fails instead of publishing an empty MP4")
  func noFrames() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let completed = AsyncThrowingStream<Double, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let writer = try ComputerUseVideoWriter(
      url: url, size: CGSize(width: 640, height: 480), fps: 30,
      onStarted: {},
      onFinished: {
        completed.continuation.yield($0); completed.continuation.finish()
      },
      onError: { completed.continuation.finish(throwing: $0) })
    defer { writer.cancel(); writer.queue.sync {} }
    writer.finish(duration: 3)
    await #expect(throws: BridgeError.self) { try await completed.stream.first(where: { _ in true }) }
  }
}
