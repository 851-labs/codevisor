import Foundation

public struct BrowserProtocolError: LocalizedError, Sendable, Equatable {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// A DevTools protocol message addressed by its top-level members without
/// decoding their values. One linear structural scan locates each member, so a
/// multi-megabyte screenshot or cookie list is forwarded as bytes and only the
/// small routing fields (`id`, `method`, `sessionId`) are ever decoded.
///
/// The scan checks structure, not every token. Use it for messages Chromium
/// produced or that were already validated by a full parse.
public struct BrowserProtocolMessage: Sendable {
  public let data: Data
  private let members: [BrowserProtocolScanner.Member]

  public init?(_ data: Data) {
    guard let members = data.withUnsafeBytes({ BrowserProtocolScanner(bytes: $0).scan() }) else { return nil }
    self.data = data
    self.members = members
  }

  public var keys: [String] { members.map(\.key) }

  /// The value's exact JSON bytes.
  public func raw(_ key: String) -> Data? {
    members.first { $0.key == key }.map { slice($0.value) }
  }

  public func string(_ key: String) -> String? {
    guard let value = raw(key), value.first == UInt8(ascii: "\"") else { return nil }
    if !value.contains(UInt8(ascii: "\\")) { return String(decoding: value.dropFirst().dropLast(), as: UTF8.self) }
    return (try? JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed)) as? String
  }

  public func integer(_ key: String) -> Int? {
    raw(key).flatMap { Int(String(decoding: $0, as: UTF8.self)) }
  }

  /// Fully decodes one member. Reserve this for small values.
  public func object(_ key: String) -> [String: Any]? {
    raw(key).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
  }

  /// The same message with one member's value replaced, appended, or (for
  /// `nil`) removed. Every other member keeps its exact bytes and order.
  public func setting(_ key: String, to value: Data?) -> Data {
    var output = Data(capacity: data.count + (value?.count ?? 0) + key.utf8.count + 4)
    output.append(UInt8(ascii: "{"))
    var replaced = false
    for member in members {
      if member.key == key {
        guard let value, !replaced else { continue }
        replaced = true
        Self.appendSeparator(&output)
        output.append(slice(member.member.lowerBound..<member.value.lowerBound))
        output.append(value)
      } else {
        Self.appendSeparator(&output)
        output.append(slice(member.member))
      }
    }
    if !replaced, let value {
      Self.appendSeparator(&output)
      output.append(Self.encode(key))
      output.append(UInt8(ascii: ":"))
      output.append(value)
    }
    output.append(UInt8(ascii: "}"))
    return output
  }

  /// A JSON string literal for `value`.
  public static func encode(_ value: String) -> Data {
    (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
      ?? Data("\"\"".utf8)
  }

  /// `{"id":<id>,"result"|"error":<value>}`, assembled from raw member bytes.
  public static func response(id: Data, result: Data? = nil, error: Data? = nil) -> Data {
    var output = Data(capacity: id.count + (result?.count ?? 0) + (error?.count ?? 0) + 24)
    output.append(contentsOf: Array("{\"id\":".utf8))
    output.append(id)
    if let error {
      output.append(contentsOf: Array(",\"error\":".utf8))
      output.append(error)
    } else {
      output.append(contentsOf: Array(",\"result\":".utf8))
      output.append(result ?? Data("{}".utf8))
    }
    output.append(UInt8(ascii: "}"))
    return output
  }

  /// The raw `result` of a command reply, or the reply's error.
  public static func result(ofReply reply: Data) throws -> Data {
    guard let message = BrowserProtocolMessage(reply) else { throw BrowserProtocolError("Invalid browser reply") }
    if message.raw("error") != nil {
      let error = message.object("error")
      throw BrowserProtocolError(error?["message"] as? String ?? "Browser command failed")
    }
    return message.raw("result") ?? Data("{}".utf8)
  }

  private func slice(_ range: Range<Int>) -> Data {
    data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
  }

  private static func appendSeparator(_ output: inout Data) {
    if output.count > 1 { output.append(UInt8(ascii: ",")) }
  }
}

/// Splits a newline-delimited byte stream into lines. Each byte is searched
/// once, and consumed lines are dropped once per chunk rather than once per
/// line, so arbitrarily large messages arriving in small chunks stay linear.
public struct BrowserProtocolLineBuffer: Sendable {
  private var buffer = Data()
  private var scanned = 0
  public init() {}

  /// Bytes of the incomplete line waiting for its newline.
  public var pendingCount: Int { buffer.count }

  public mutating func append(_ chunk: Data) -> [Data] {
    guard !chunk.isEmpty else { return [] }
    buffer.append(chunk)
    var lines: [Data] = []
    var lineStart = 0
    buffer.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var position = scanned
      while position < bytes.count, let found = memchr(base + position, 0x0A, bytes.count - position) {
        let newline = base.distance(to: UnsafeRawPointer(found))
        lines.append(Data(bytes: base + lineStart, count: newline - lineStart))
        lineStart = newline + 1
        position = lineStart
      }
    }
    if lineStart > 0 { buffer = Data(buffer[(buffer.startIndex + lineStart)...]) }
    scanned = buffer.count
    return lines
  }
}
