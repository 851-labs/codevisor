public struct BenchClockExchange: Sendable, Equatable {
  public var localSendNs: Int64
  public var remoteReceiveNs: Int64
  public var remoteSendNs: Int64
  public var localReceiveNs: Int64

  public init(localSendNs: Int64, remoteReceiveNs: Int64, remoteSendNs: Int64, localReceiveNs: Int64) {
    self.localSendNs = localSendNs
    self.remoteReceiveNs = remoteReceiveNs
    self.remoteSendNs = remoteSendNs
    self.localReceiveNs = localReceiveNs
  }

  public var roundTripNs: Int64 {
    (localReceiveNs - localSendNs) - (remoteSendNs - remoteReceiveNs)
  }

  var offsetNs: Double {
    (Double(remoteReceiveNs - localSendNs) + Double(remoteSendNs - localReceiveNs)) / 2
  }

  var localMidpointNs: Int64 {
    localSendNs + (localReceiveNs - localSendNs) / 2
  }
}
