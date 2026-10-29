import ScreenSharingBench

struct ClockProbeRecord: Encodable {
  let burst: Int
  let localSendNs: Int64
  let remoteReceiveNs: Int64
  let remoteSendNs: Int64
  let localReceiveNs: Int64

  static func records(_ bursts: [[BenchClockExchange]]) -> [ClockProbeRecord] {
    bursts.enumerated().flatMap { burst, exchanges in
      exchanges.map {
        ClockProbeRecord(
          burst: burst, localSendNs: $0.localSendNs, remoteReceiveNs: $0.remoteReceiveNs,
          remoteSendNs: $0.remoteSendNs, localReceiveNs: $0.localReceiveNs)
      }
    }
  }
}
