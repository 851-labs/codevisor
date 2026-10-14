#if os(macOS)
  import Foundation
  import ScreenCaptureKit

  protocol ScreenSharingCaptureStream: AnyObject, Sendable {
    nonisolated(nonsending) func startCapture() async throws
    nonisolated(nonsending) func stopCapture() async throws
    nonisolated(nonsending) func updateConfiguration(_ configuration: SCStreamConfiguration) async throws
  }

  final class ScreenSharingSystemCaptureStream: ScreenSharingCaptureStream, @unchecked Sendable {
    private let stream: SCStream

    init(stream: SCStream) { self.stream = stream }

    nonisolated(nonsending) func startCapture() async throws { try await stream.startCapture() }
    nonisolated(nonsending) func stopCapture() async throws { try await stream.stopCapture() }
    nonisolated(nonsending) func updateConfiguration(_ configuration: SCStreamConfiguration) async throws {
      try await stream.updateConfiguration(configuration)
    }
  }

  struct ScreenSharingCaptureContent: Equatable, Sendable {
    let style: String
    let widthPoints: Double
    let heightPoints: Double
    let pointPixelScale: Float
  }

  protocol ScreenSharingCaptureTarget {
    var captureContent: ScreenSharingCaptureContent { get }
    func makeCaptureStream(
      configuration: SCStreamConfiguration, output: ScreenSharingCaptureOutput
    ) throws -> any ScreenSharingCaptureStream
  }

  extension SCContentFilter: ScreenSharingCaptureTarget {
    var captureContent: ScreenSharingCaptureContent {
      ScreenSharingCaptureContent(
        style: String(describing: style), widthPoints: Double(contentRect.width),
        heightPoints: Double(contentRect.height), pointPixelScale: pointPixelScale)
    }

    func makeCaptureStream(
      configuration: SCStreamConfiguration, output: ScreenSharingCaptureOutput
    ) throws -> any ScreenSharingCaptureStream {
      let stream = SCStream(filter: self, configuration: configuration, delegate: output)
      try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
      try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.audioQueue)
      return ScreenSharingSystemCaptureStream(stream: stream)
    }
  }
#endif
