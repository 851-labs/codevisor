import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use video files")
struct ComputerUseVideoWriterTests {
  @Test("A static screen remains visible for the full recording duration in the MP4")
  func staticDuration() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let completed = ComputerUseRecordingResult<Double>()
    let started = ComputerUseRecordingResult<Bool>()
    let writer = try ComputerUseVideoWriter(
      url: url, size: CGSize(width: 640, height: 480), fps: 30,
      onStarted: { started.complete(.success(true)) }, onFinished: { completed.complete(.success($0)) },
      onError: { completed.complete(.failure($0)) })
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let frame = try #require(pixel)
    CVPixelBufferLockBaseAddress(frame, [])
    memset(CVPixelBufferGetBaseAddress(frame), 128, CVPixelBufferGetDataSize(frame))
    CVPixelBufferUnlockBaseAddress(frame, [])
    writer.queue.sync { writer.append(frame, at: CMTime(seconds: 100, preferredTimescale: 600)) }
    #expect(try started.wait())
    writer.finish(duration: 3)
    #expect(try completed.wait() >= 3)
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
  func noFrames() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let completed = ComputerUseRecordingResult<Double>()
    let writer = try ComputerUseVideoWriter(
      url: url, size: CGSize(width: 640, height: 480), fps: 30,
      onStarted: {}, onFinished: { completed.complete(.success($0)) }, onError: { completed.complete(.failure($0)) })
    writer.finish(duration: 3)
    #expect(throws: BridgeError.self) { try completed.wait() }
  }
}
