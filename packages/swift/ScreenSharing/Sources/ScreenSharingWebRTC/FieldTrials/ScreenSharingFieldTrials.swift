import Foundation
import ScreenSharing
@preconcurrency import WebRTC
import WebRTCProcessFieldTrials

final class ScreenSharingFieldTrials: @unchecked Sendable {
  static let product = [
    "WebRTC-ForcePlayoutDelay": "min_ms:15,max_ms:80", "WebRTC-Video-Pacing": "factor:10",
    "WebRTC-FrameDropper": "Disabled",
  ]
  static let productString = product.sorted { $0.key < $1.key }.map { "\($0.key)/\($0.value)/" }.joined()
  static let process = ScreenSharingFieldTrials(apply: { CodevisorInstallWebRTCProcessFieldTrials($0) })

  private let apply: @Sendable ([String: String]) -> Void
  private let lock = NSLock()
  private var installed = false

  init(apply: @escaping @Sendable ([String: String]) -> Void) { self.apply = apply }

  func makeFactory(
    codecFactory: ScreenSharingCodecFactory, metrics: ScreenSharingMetrics
  ) -> RTCPeerConnectionFactory {
    install()
    metrics.label("fieldTrials", Self.productString)
    return RTCPeerConnectionFactory(encoderFactory: codecFactory, decoderFactory: codecFactory)
  }

  func install() {
    lock.withLock {
      guard !installed else { return }

      apply(Self.product)
      installed = true
    }
  }
}
