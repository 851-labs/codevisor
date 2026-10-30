import CoreMedia
import CoreVideo
import ScreenSharing
import ScreenSharingBenchScenes

@MainActor
struct EncodeLabQualityPass {
  struct Result {
    let samples: [EncodeLabQualitySample]
    let decodeMs: [Double]
    let atNativeSize: Bool
  }

  let setup: BenchSceneSetup
  let trace: EncodeLabTrace
  let samplesWanted: Int

  func run() async throws -> Result {
    let source = try EncodeLabFrameSource(setup: setup, config: trace.config)
    let reference = try EncodeLabPixelTransfer(
      width: trace.config.width, height: trace.config.height, format: trace.config.referenceFormat)
    let comparer = try nativeComparer
    var screen = EncodeLabDecodedScreen(config: trace.config)
    var samples: [EncodeLabQualitySample] = []
    var decodeMs: [Double] = []
    for event in trace.events {
      let started = ScreenSharingMetrics.nowNs
      try screen.decode(trace.outputs(ofFrame: event.frame))
      decodeMs.append(Double(ScreenSharingMetrics.nowNs - started) / 1e6)
      guard sampled(event) else { continue }

      let native = try await source.nativePicture(forVersion: event.version)
      let original = try reference.transfer(try await source.picture(forVersion: event.version))
      let nativeQuality = try screen.singleImage.flatMap { try comparer?.compare(native: native, shown: $0) }
      samples.append(try screen.compare(with: original, event: event, native: nativeQuality))
    }
    return Result(samples: samples, decodeMs: decodeMs, atNativeSize: comparer == nil)
  }

  private var nativeComparer: EncodeLabNativeComparer? {
    get throws {
      guard setup.canvas.pixelWidth != trace.config.width else { return nil }

      return try EncodeLabNativeComparer(canvas: setup.canvas, format: trace.config.referenceFormat)
    }
  }

  private var stride: Int {
    let measured = trace.events.filter { $0.tick >= trace.warmUpTicks }.count
    return max(1, measured / max(1, samplesWanted))
  }

  private func sampled(_ event: EncodeLabFrameEvent) -> Bool {
    guard samplesWanted > 0, event.tick >= trace.warmUpTicks else { return false }

    return event.refresh != nil || event.frame.isMultiple(of: stride)
  }
}
