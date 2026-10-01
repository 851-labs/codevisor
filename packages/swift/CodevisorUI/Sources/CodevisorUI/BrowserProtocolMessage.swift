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
  private struct Member: Sendable {
    var key: String
    /// The raw `"key":value` bytes, relative to `data.startIndex`.
    var member: Range<Int>
    var value: Range<Int>
  }
  public let data: Data
  private let members: [Member]

  public init?(_ data: Data) {
    guard let members = data.withUnsafeBytes({ Self.scan(Scanner(bytes: $0)) }) else { return nil }
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

  private static func scan(_ scanner: Scanner) -> [Member]? {
    var members: [Member] = []
    var index = scanner.skipWhitespace(0)
    guard scanner.byte(index) == UInt8(ascii: "{") else { return nil }
    index = scanner.skipWhitespace(index + 1)
    if scanner.byte(index) == UInt8(ascii: "}") {
      return scanner.skipWhitespace(index + 1) == scanner.count ? [] : nil
    }
    while true {
      guard scanner.byte(index) == UInt8(ascii: "\""), let keyEnd = scanner.skipString(index),
        let key = scanner.decodeKey(index..<keyEnd)
      else { return nil }
      var cursor = scanner.skipWhitespace(keyEnd)
      guard scanner.byte(cursor) == UInt8(ascii: ":") else { return nil }
      cursor = scanner.skipWhitespace(cursor + 1)
      guard let valueEnd = scanner.skipValue(cursor) else { return nil }
      members.append(Member(key: key, member: index..<valueEnd, value: cursor..<valueEnd))
      cursor = scanner.skipWhitespace(valueEnd)
      switch scanner.byte(cursor) {
      case UInt8(ascii: ","): index = scanner.skipWhitespace(cursor + 1)
      case UInt8(ascii: "}"): return scanner.skipWhitespace(cursor + 1) == scanner.count ? members : nil
      default: return nil
      }
    }
  }
}

private struct Scanner {
  let bytes: UnsafeRawBufferPointer
  var count: Int { bytes.count }

  func byte(_ index: Int) -> UInt8? { index < bytes.count ? bytes[index] : nil }

  func skipWhitespace(_ start: Int) -> Int {
    var index = start
    while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
    return index
  }

  /// The index after the closing quote of the string that starts at `start`.
  func skipString(_ start: Int) -> Int? {
    guard let base = bytes.baseAddress else { return nil }
    var index = start + 1
    while index < bytes.count {
      guard let found = memchr(base + index, Int32(UInt8(ascii: "\"")), bytes.count - index) else { return nil }
      let quote = base.distance(to: UnsafeRawPointer(found))
      var backslashes = 0
      while quote - backslashes - 1 > start, bytes[quote - backslashes - 1] == UInt8(ascii: "\\") { backslashes += 1 }
      if backslashes.isMultiple(of: 2) { return quote + 1 }
      index = quote + 1
    }
    return nil
  }

  func skipValue(_ start: Int) -> Int? {
    guard let first = byte(start) else { return nil }
    switch first {
    case UInt8(ascii: "\""): return skipString(start)
    case UInt8(ascii: "{"), UInt8(ascii: "["):
      var depth = 0
      var index = start
      while index < bytes.count {
        switch bytes[index] {
        case UInt8(ascii: "\""):
          guard let end = skipString(index) else { return nil }
          index = end
          continue
        case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
          depth -= 1
          if depth == 0 { return index + 1 }
        default: break
        }
        index += 1
      }
      return nil
    default:
      var index = start
      while index < bytes.count, !Self.endsScalar(bytes[index]) { index += 1 }
      return index > start ? index : nil
    }
  }

  static func isWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x20, 0x09, 0x0A, 0x0D: true
    default: false
    }
  }

  static func endsScalar(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"): true
    default: isWhitespace(byte)
    }
  }

  func decodeKey(_ range: Range<Int>) -> String? {
    let token = UnsafeRawBufferPointer(rebasing: bytes[range])
    if !token.contains(UInt8(ascii: "\\")) {
      return String(decoding: UnsafeRawBufferPointer(rebasing: token.dropFirst().dropLast()), as: UTF8.self)
    }
    return (try? JSONSerialization.jsonObject(with: Data(token), options: .fragmentsAllowed)) as? String
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
