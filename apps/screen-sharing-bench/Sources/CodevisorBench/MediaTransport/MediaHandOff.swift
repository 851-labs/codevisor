import CodevisorNet
import Foundation

enum MediaHandOff {
  private static let sizes = [64 << 10, 256 << 10, 1 << 20]
  private static let settle = Duration.milliseconds(30)

  static func measure(frames: Int) async throws -> String {
    let viewerEndpoint = try await netBindEndpoint(config: endpointConfig())
    let hostEndpoint = try await netBindEndpoint(config: endpointConfig())
    async let accepted = viewerEndpoint.accept()
    let hostConnection = try await hostEndpoint.connect(addr: viewerEndpoint.addr(), alpn: mediaAlpn(), cancel: nil)
    guard let viewerConnection = try await accepted else { throw MediaHandOffError.noConnection }

    let config = MediaSessionConfig(frameIntervalUs: 16_667, fecPercent: 0, initialRateKbps: 1_000_000)
    let host = await hostConnection.openMediaSession(config: config)
    let viewer = await viewerConnection.openMediaSession(config: config)
    let acks = Task { while case .some = await host.nextEvent() {} }
    var report =
      "| Frame | sendFrame p50 / p95 ms (Swift) | nextEvent + copy p50 / p95 ms (Swift) |\n| -- | -- | -- |\n"
    for size in sizes {
      let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })
      var sends: [Double] = []
      var receives: [Double] = []
      for _ in 0..<frames {
        sends.append(try milliseconds { try host.sendFrame(stream: 0, keyframe: false, ltrToken: nil, data: data) })
        try await Task.sleep(for: settle)
        let started = ContinuousClock.now
        guard case .frame(_, _, _, _, _, let bytes, _, _) = await viewer.nextEvent(), bytes.data.count == size else {
          throw MediaHandOffError.frameMissing
        }
        receives.append(milliseconds(ContinuousClock.now - started))
      }
      report += "| \(size >> 10) KiB | \(summary(sends)) | \(summary(receives)) |\n"
    }
    host.close()
    viewer.close()
    await acks.value
    hostConnection.close(code: 0, reason: "done")
    await hostEndpoint.close()
    await viewerEndpoint.close()
    return report
  }

  private static func endpointConfig() -> NetEndpointConfig {
    NetEndpointConfig(
      secretKeyHex: netGenerateSecretKeyHex(), relays: [], trustAnchorsPem: [], pathPolicy: "direct-only",
      alpns: [mediaAlpn()])
  }

  private static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let started = ContinuousClock.now
    try body()
    return milliseconds(ContinuousClock.now - started)
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  private static func summary(_ values: [Double]) -> String {
    let sorted = values.sorted()
    let at = { (p: Double) in sorted[Int((Double(sorted.count - 1) * p).rounded())] }
    return String(format: "%.3f / %.3f", at(0.5), at(0.95))
  }
}

enum MediaHandOffError: Error {
  case noConnection
  case frameMissing
}
