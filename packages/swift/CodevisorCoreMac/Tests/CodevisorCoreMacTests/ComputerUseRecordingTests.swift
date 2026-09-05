import AVFoundation
import Foundation
import ScreenCaptureKit
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use recording")
struct ComputerUseRecordingTests {
  @Test("Recording requires exactly one valid target and bounded capture settings")
  func options() throws {
    let window = try ComputerUseRecordingOptions(["window_id": 42])
    #expect(window.windowID == 42)
    #expect(window.displayID == nil)
    #expect(window.fps == 30 && window.maximumDuration == 60 && window.maximumDimension == 1920)
    #expect(window.showsCursor)
    let display = try ComputerUseRecordingOptions(["display_id": 4, "fps": 60, "show_cursor": false])
    #expect(display.displayID == 4 && !display.showsCursor)
    for args: [String: Any] in [
      [:], ["window_id": 1, "display_id": 2], ["window_id": -1], ["window_id": 1.5],
      ["display_id": true], ["window_id": 1, "fps": 0], ["window_id": 1, "fps": 61],
      ["window_id": 1, "max_duration_seconds": 301], ["window_id": 1, "max_dimension": 99999],
      ["window_id": 1, "show_cursor": "yes"],
    ] {
      #expect(throws: BridgeError.self) { try ComputerUseRecordingOptions(args) }
    }
  }

  @Test("Video dimensions preserve aspect ratio, stay even and never upscale")
  func dimensions() throws {
    #expect(
      try computerUseRecordingSize(CGSize(width: 3840, height: 2160), maximumDimension: 1920)
        == CGSize(width: 1920, height: 1080))
    #expect(
      try computerUseRecordingSize(CGSize(width: 801, height: 601), maximumDimension: 1920)
        == CGSize(width: 800, height: 600))
    #expect(throws: BridgeError.self) { try computerUseRecordingSize(.zero, maximumDimension: 1920) }
  }

  @Test("A video is returned only after the native output finishes; repeated stop is harmless")
  func finalization() throws {
    let recording = ComputerUseRecording(
      sessionID: "a", target: [:], options: try .init(["window_id": 1]), size: CGSize(width: 800, height: 600),
      directory: FileManager.default.temporaryDirectory)
    #expect(recording.metadata()["file"] == nil)
    recording.captureStarted()
    #expect(recording.metadata()["status"] as? String == "recording")
    #expect(recording.metadata()["file"] == nil)
    recording.captureFinished(duration: 3)
    #expect(recording.metadata()["status"] as? String == "stopped")
    #expect((recording.metadata()["file"] as? [String: Any])?["mimeType"] as? String == "video/mp4")
    try recording.stop()
    try recording.stop()
    #expect(recording.isFinished)
  }

  @Test("Native recording failures do not produce a successful video artifact")
  func failedOutput() throws {
    let recording = ComputerUseRecording(
      sessionID: "a", target: [:], options: try .init(["window_id": 1]), size: CGSize(width: 800, height: 600),
      directory: FileManager.default.temporaryDirectory)
    recording.fail(BridgeError("disk full"))
    #expect(recording.metadata()["status"] as? String == "failed")
    #expect(recording.metadata()["file"] == nil)
    #expect(throws: BridgeError.self) { try recording.stop() }
  }

  @Test("Session cleanup can cancel a reserved recording before its stream starts")
  func earlyCancellation() throws {
    let recording = ComputerUseRecording(
      sessionID: "a", target: [:], options: try .init(["window_id": 1]), size: CGSize(width: 800, height: 600),
      directory: FileManager.default.temporaryDirectory)
    try recording.stop(reason: "session_closed")
    #expect(recording.isFinished)
    #expect(recording.metadata()["status"] as? String == "cancelled")
    #expect(recording.metadata()["file"] == nil)
    try recording.stop()
  }

  @Test("Recording status does not infer or accept an unknown recording")
  func missingRecording() throws {
    let manager = ComputerUseRecordings(directory: FileManager.default.temporaryDirectory)
    #expect((try manager.status(sessionID: "a", id: nil)["recordings"] as? [[String: Any]])?.isEmpty == true)
    #expect(throws: BridgeError.self) { try manager.stop(sessionID: "b", id: "a") }
    #expect(throws: BridgeError.self) { try manager.start(sessionID: "", agentLabel: nil, arguments: ["window_id": 1]) }
  }

  @Test("Callback completion is retained even before waiting and timeout never invents a result")
  func callbacks() throws {
    let result = ComputerUseRecordingResult<Int>()
    #expect(throws: BridgeError.self) { try result.wait(timeout: 0) }
    result.complete(.success(3))
    result.complete(.success(4))
    #expect(try result.wait() == 3)
  }

  @Test("Recording size reflects new bytes instead of cached URL metadata")
  func currentFileSize() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-size-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data().write(to: url)
    #expect(computerUseRecordingFileSize(url) == 0)
    try Data(repeating: 0, count: 123).write(to: url)
    #expect(computerUseRecordingFileSize(url) == 123)
  }
}
