#if os(macOS)
  import Foundation
  import ScreenCaptureKit

  /// The whole ScreenCaptureKit surface `ScreenSharingCapture` drives once a target is resolved:
  /// start, reconfigure, stop. In the product every call forwards to a real `SCStream`; a test
  /// supplies a stream it controls and the capture's state machine runs without Screen Recording
  /// permission.
  ///
  /// The calls stay on the caller's actor (`nonisolated(nonsending)`), which is how the capture
  /// already reached ScreenCaptureKit's completion-handler methods: the main-actor
  /// `SCStreamConfiguration` it just built is handed straight over, never sent across a region.
  protocol ScreenSharingCaptureStream: AnyObject, Sendable {
    nonisolated(nonsending) func startCapture() async throws
    nonisolated(nonsending) func stopCapture() async throws
    nonisolated(nonsending) func updateConfiguration(_ configuration: SCStreamConfiguration) async throws
  }

  /// The production stream. A thin adapter rather than a conformance on `SCStream` itself:
  /// ScreenCaptureKit is imported without concurrency annotations, so naming the boundary here
  /// keeps the `Sendable` reasoning in one reviewable place instead of retroactively asserting
  /// something about a framework class. It forwards and does nothing else.
  final class ScreenSharingSystemCaptureStream: ScreenSharingCaptureStream, @unchecked Sendable {
    private let stream: SCStream

    init(stream: SCStream) { self.stream = stream }

    nonisolated(nonsending) func startCapture() async throws { try await stream.startCapture() }
    nonisolated(nonsending) func stopCapture() async throws { try await stream.stopCapture() }
    nonisolated(nonsending) func updateConfiguration(_ configuration: SCStreamConfiguration) async throws {
      try await stream.updateConfiguration(configuration)
    }
  }

  /// How the resolved target describes itself in telemetry. Reading these scalars is the only
  /// thing the capture does with a content filter besides handing it to `SCStream`, so a target
  /// that is not an `SCContentFilter` can report the same facts.
  struct ScreenSharingCaptureContent: Equatable, Sendable {
    let style: String
    let widthPoints: Double
    let heightPoints: Double
    let pointPixelScale: Float
  }

  /// A resolved thing to capture. The display, owned-window and picker entry points each resolve
  /// their own `SCContentFilter` and then run the one shared start path over it.
  protocol ScreenSharingCaptureTarget {
    var captureContent: ScreenSharingCaptureContent { get }
    /// Creates the stream and attaches `output` as both its sample output and its delegate.
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
      return ScreenSharingSystemCaptureStream(stream: stream)
    }
  }
#endif
