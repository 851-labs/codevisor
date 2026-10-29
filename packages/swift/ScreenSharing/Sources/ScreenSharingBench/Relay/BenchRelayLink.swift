public struct BenchRelayLink<Packet: Sendable>: Sendable {
  private struct InFlight: Sendable {
    let dueNs: Int64
    let packet: Packet
  }

  public private(set) var statistics = BenchRelayStatistics()
  public private(set) var traffic: BenchRelayTraffic
  private var model: BenchNetworkModel
  private var inFlight: [InFlight] = []
  private var nextInFlight = 0

  public init(conditions: BenchNetworkConditions, seed: UInt64, originNs: Int64) {
    model = BenchNetworkModel(conditions: conditions, seed: seed)
    traffic = BenchRelayTraffic(originNs: originNs)
  }

  public var nextDueNs: Int64? {
    nextInFlight < inFlight.count ? inFlight[nextInFlight].dueNs : nil
  }

  public mutating func offer(_ packet: Packet, byteCount: Int, atNs sentNs: Int64) {
    traffic.record(byteCount: byteCount, atNs: sentNs)
    let fate = model.send(byteCount: byteCount, atNs: sentNs)
    statistics.record(fate, byteCount: byteCount)
    guard case .delivered(let dueNs) = fate else { return }

    inFlight.append(InFlight(dueNs: dueNs, packet: packet))
  }

  public mutating func recordSendFailure() {
    statistics.sendFailures += 1
  }

  public mutating func takeDue(atNs nowNs: Int64) -> [Packet] {
    var due: [Packet] = []
    while nextInFlight < inFlight.count, inFlight[nextInFlight].dueNs <= nowNs {
      due.append(inFlight[nextInFlight].packet)
      nextInFlight += 1
    }
    compact()
    return due
  }

  private mutating func compact() {
    guard nextInFlight > 0, nextInFlight * 2 >= inFlight.count else { return }

    inFlight.removeFirst(nextInFlight)
    nextInFlight = 0
  }
}
