import Foundation

final class CloudDirectChannelState {
  let cipher: CloudChannelCipher
  var nextOutboundSeq: UInt64
  var nextInboundSeq: UInt64 = 0
  let flowControlled: Bool
  let compressed: Bool
  var inboundCredit = 0
  var receivedInbound = false
  let onMessage: @Sendable (Data, Int) -> Void
  let onCredit: @Sendable (Int) -> Void
  let onClosed: @Sendable (CloudChannelCloseReason?) -> Void

  init(
    cipher: CloudChannelCipher,
    nextOutboundSeq: UInt64,
    flowControlled: Bool,
    compressed: Bool,
    onMessage: @escaping @Sendable (Data, Int) -> Void,
    onCredit: @escaping @Sendable (Int) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) {
    self.cipher = cipher
    self.nextOutboundSeq = nextOutboundSeq
    self.flowControlled = flowControlled
    self.compressed = compressed
    self.onMessage = onMessage
    self.onCredit = onCredit
    self.onClosed = onClosed
  }

  func receiveData(_ payload: Data, channelId: String, seq: UInt64) -> CloudChannelCloseReason? {
    do {
      let plaintext = try openPayload(payload, channelId: channelId, seq: seq)
      let sealedBytes = payload.count
      if flowControlled {
        guard sealedBytes <= inboundCredit else { return .protocolError }
        inboundCredit -= sealedBytes
      }
      onMessage(plaintext, sealedBytes)
      // No auto-replenish: machines never gate structured sends on
      // credit unless the opener negotiated flow control, so a
      // per-message credit frame would be a pure no-op.
      return nil
    } catch {
      return .cryptoError
    }
  }

  private func openPayload(_ payload: Data, channelId: String, seq: UInt64) throws -> Data {
    var plaintext = try cipher.open(
      payload,
      channelId: channelId,
      direction: .responderToOpener,
      seq: seq
    )
    if compressed {
      plaintext = try Self.unframe(plaintext)
    }
    return plaintext
  }

  func sealData(_ plaintext: Data, channelId: String) throws -> (frame: CloudRelayFrame, payload: Data) {
    let seq = nextOutboundSeq
    nextOutboundSeq += 1
    let body = compressed ? Data([CloudDeflate.framingRaw]) + plaintext : plaintext
    let sealed = try cipher.seal(
      body,
      channelId: channelId,
      direction: .openerToResponder,
      seq: seq
    )
    return (frame: .data(channelId: channelId, seq: seq), payload: sealed)
  }

  /// Strips the negotiated framing byte, inflating DEFLATE bodies.
  private static func unframe(_ plaintext: Data) throws -> Data {
    guard let framing = plaintext.first else { throw CloudDeflateError.corruptInput }
    let body = plaintext.dropFirst()
    switch framing {
    case CloudDeflate.framingRaw: return Data(body)
    case CloudDeflate.framingDeflate: return try CloudDeflate.inflate(Data(body))
    default: throw CloudDeflateError.corruptInput
    }
  }
}
