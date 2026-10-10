import Foundation

// MARK: - Binary relay envelopes

/// One decoded relay envelope: the raw JSON header bytes plus the payload.
public struct CloudRelayEnvelope: Sendable {
  public var header: Data
  public var payload: Data

  public init(header: Data, payload: Data) {
    self.header = header
    self.payload = payload
  }
}

/// The relay's binary framing, the Swift twin of @codevisor/api
/// encodeRelayEnvelopes: a binary WebSocket message is one or more envelopes,
/// each `u32 BE header length | header JSON | u32 BE payload length | payload`.
/// Senders may coalesce several envelopes into one message; receivers process
/// them in order.
public enum CloudRelayWire {
  public static func encode(_ envelopes: [CloudRelayEnvelope]) -> Data {
    var message = Data()
    for envelope in envelopes {
      withUnsafeBytes(of: UInt32(envelope.header.count).bigEndian) {
        message.append(contentsOf: $0)
      }
      message.append(envelope.header)
      withUnsafeBytes(of: UInt32(envelope.payload.count).bigEndian) {
        message.append(contentsOf: $0)
      }
      message.append(envelope.payload)
    }
    return message
  }

  public static func decode(_ message: Data) throws -> [CloudRelayEnvelope] {
    var envelopes: [CloudRelayEnvelope] = []
    var offset = message.startIndex
    while offset < message.endIndex {
      let headerLength = try readLength(in: message, offset: &offset)
      let header = try readBytes(headerLength, from: message, offset: &offset)
      let payloadLength = try readLength(in: message, offset: &offset)
      let payload = try readBytes(payloadLength, from: message, offset: &offset)
      envelopes.append(CloudRelayEnvelope(header: header, payload: payload))
    }
    guard !envelopes.isEmpty else { throw CloudRelayWireError.empty }
    return envelopes
  }

  private static func readLength(in message: Data, offset: inout Data.Index) throws -> Int {
    guard message.distance(from: offset, to: message.endIndex) >= 4 else {
      throw CloudRelayWireError.truncated
    }
    let end = message.index(offset, offsetBy: 4)
    var length: UInt32 = 0
    for byte in message[offset..<end] {
      length = length << 8 | UInt32(byte)
    }
    offset = end
    return Int(length)
  }

  private static func readBytes(_ count: Int, from message: Data, offset: inout Data.Index) throws -> Data {
    guard message.distance(from: offset, to: message.endIndex) >= count else {
      throw CloudRelayWireError.truncated
    }
    let end = message.index(offset, offsetBy: count)
    defer { offset = end }
    return Data(message[offset..<end])
  }
}

public enum CloudRelayWireError: Error, Equatable, Sendable {
  case truncated
  case empty
}
