import ScreenSharing
import Foundation
import Testing

@testable import ScreenSharingRigKit

struct RigConfigurationTests {
  static let token = "0123456789abcdef0123"

  static func json(_ fields: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
  }

  @Test func hostDefaults() throws {
    let configuration = try RigConfiguration.parse(Self.json(["role": "host", "token": Self.token]))
    #expect(configuration.role == .host)
    #expect(configuration.port == 48731)
    #expect(configuration.controlPort == 48732)
    #expect(configuration.video.width == 1920)
    #expect(configuration.video.height == 1080)
    #expect(configuration.video.framesPerSecond == 60)
    #expect(configuration.video.bitrate == 12_000_000)
    #expect(configuration.codec == .h264)
    #expect(configuration.capture == .synthetic)
    #expect(configuration.hud == true)
    #expect(configuration.peer == nil)
    #expect(configuration.hostBaseURL == nil)
  }

  @Test func viewerRequiresPeerAndBuildsHostURL() throws {
    #expect(throws: (any Error).self) {
      try RigConfiguration.parse(Self.json(["role": "viewer", "token": Self.token]))
    }
    let bare = try RigConfiguration.parse(Self.json(["role": "viewer", "token": Self.token, "peer": "192.168.10.191"]))
    #expect(bare.hostBaseURL == URL(string: "http://192.168.10.191:48731"))
    let explicit = try RigConfiguration.parse(
      Self.json(["role": "viewer", "token": Self.token, "peer": "host.local:5000", "port": 6000]))
    #expect(explicit.hostBaseURL == URL(string: "http://host.local:5000"))
  }

  @Test(arguments: [
    "synthetic", "workload:1920x1080@60", "workload:1280x720@30", "display:1", "display:69734400",
    "virtual:1920x1080@60", "virtual:2560x1440@30", "virtual-desktop:1920x1080@60", "app:com.apple.dt.Xcode",
    "app:com.apple.finder", "window:4711",
  ])
  func captureSourcesRoundTrip(_ text: String) throws {
    let source = try RigConfiguration.CaptureSource.parse(text)
    #expect(source.description == text)
  }

  @Test(arguments: [
    "", "window", "display:0", "display:-1", "display:x", "workload:1920x1080", "workload:1921x1080@60",
    "workload:1920x1080@0", "workload:1920x1080@121", "workload:100x100@60", "workload:4000x1080@60",
    "virtual:1920x1080", "virtual:1921x1080@60", "virtual:", "virtual-desktop:1920x1080", "app:", "app:has space",
    "window:0", "window:x",
  ])
  func invalidCaptureSources(_ text: String) {
    #expect(throws: (any Error).self) { try RigConfiguration.CaptureSource.parse(text) }
  }

  @Test func rejectsUnknownKeysBadTokensAndViewerCapture() {
    #expect(throws: (any Error).self) {
      try RigConfiguration.parse(Self.json(["role": "host", "token": Self.token, "tokn": "typo"]))
    }
    #expect(throws: (any Error).self) { try RigConfiguration.parse(Self.json(["role": "host", "token": "short"])) }
    #expect(throws: (any Error).self) {
      try RigConfiguration.parse(Self.json(["role": "host", "token": "has whitespace in it 12345"]))
    }
    #expect(throws: (any Error).self) {
      try RigConfiguration.parse(
        Self.json(["role": "viewer", "peer": "h", "token": Self.token, "capture": "synthetic"]))
    }
    #expect(throws: (any Error).self) { try RigConfiguration.parse(Self.json(["role": "admin", "token": Self.token])) }
    #expect(throws: (any Error).self) {
      try RigConfiguration.parse(Self.json(["role": "host", "token": Self.token, "port": 70000]))
    }
    #expect(throws: (any Error).self) {
      try RigConfiguration.parse(Self.json(["role": "host", "token": Self.token, "fps": 12.5]))
    }
    #expect(throws: (any Error).self) {
      try RigConfiguration.parse(Self.json(["role": "host", "token": Self.token, "hud": "yes"]))
    }
    #expect(throws: (any Error).self) { try RigConfiguration.parse(Data("not json".utf8)) }
    #expect(throws: (any Error).self) { try RigConfiguration.parse(Data("[]".utf8)) }
  }

  @Test func acceptsExplicitVideoAndCodec() throws {
    let configuration = try RigConfiguration.parse(
      Self.json([
        "role": "host", "token": Self.token, "width": 1280, "height": 720, "fps": 30, "bitrate": 4_000_000,
        "codec": "hevc", "capture": "workload:1280x720@30", "hud": false, "telemetryDirectory": "/tmp/x",
      ]))
    #expect(configuration.video.width == 1280)
    #expect(configuration.video.framesPerSecond == 30)
    #expect(configuration.codec == .hevc)
    #expect(configuration.capture == .workload(width: 1280, height: 720, framesPerSecond: 30))
    #expect(configuration.hud == false)
    #expect(configuration.telemetryDirectory == "/tmp/x")
  }
}

extension RigConfigurationTests {
  @Test func virtualIsAHostSourceDistinctFromWorkload() throws {
    let virtual = try RigConfiguration.CaptureSource.parse("virtual:1920x1080@60")
    #expect(virtual == .virtual(width: 1920, height: 1080, framesPerSecond: 60))
    #expect(virtual != .workload(width: 1920, height: 1080, framesPerSecond: 60))
    let configuration = try RigConfiguration.parse(
      Self.json(["role": "host", "token": Self.token, "capture": "virtual:1920x1080@60"]))
    #expect(configuration.capture.description == "virtual:1920x1080@60")
  }
}
