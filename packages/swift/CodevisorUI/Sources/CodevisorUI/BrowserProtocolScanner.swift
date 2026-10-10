import Foundation

struct BrowserProtocolScanner {
  struct Member: Sendable {
    var key: String
    /// The raw `"key":value` bytes, relative to `data.startIndex`.
    var member: Range<Int>
    var value: Range<Int>
  }

  func scan() -> [Member]? {
    var members: [Member] = []
    var index = skipWhitespace(0)
    guard byte(index) == UInt8(ascii: "{") else { return nil }
    index = skipWhitespace(index + 1)
    if byte(index) == UInt8(ascii: "}") {
      return skipWhitespace(index + 1) == count ? [] : nil
    }
    while true {
      guard let member = scanMember(index) else { return nil }
      members.append(member)
      let cursor = skipWhitespace(member.value.upperBound)
      switch byte(cursor) {
      case UInt8(ascii: ","): index = skipWhitespace(cursor + 1)
      case UInt8(ascii: "}"): return skipWhitespace(cursor + 1) == count ? members : nil
      default: return nil
      }
    }
  }

  private func scanMember(_ index: Int) -> Member? {
    guard byte(index) == UInt8(ascii: "\""), let keyEnd = skipString(index),
      let key = decodeKey(index..<keyEnd)
    else { return nil }
    var cursor = skipWhitespace(keyEnd)
    guard byte(cursor) == UInt8(ascii: ":") else { return nil }
    cursor = skipWhitespace(cursor + 1)
    guard let valueEnd = skipValue(cursor) else { return nil }
    return Member(key: key, member: index..<valueEnd, value: cursor..<valueEnd)
  }

  let bytes: UnsafeRawBufferPointer
  var count: Int { bytes.count }

  private func byte(_ index: Int) -> UInt8? { index < bytes.count ? bytes[index] : nil }

  private func skipWhitespace(_ start: Int) -> Int {
    var index = start
    while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
    return index
  }

  /// The index after the closing quote of the string that starts at `start`.
  private func skipString(_ start: Int) -> Int? {
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

  private func skipValue(_ start: Int) -> Int? {
    guard let first = byte(start) else { return nil }
    switch first {
    case UInt8(ascii: "\""): return skipString(start)
    case UInt8(ascii: "{"), UInt8(ascii: "["): return skipContainer(start)
    default: return skipScalar(start)
    }
  }

  private func skipContainer(_ start: Int) -> Int? {
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
  }

  private func skipScalar(_ start: Int) -> Int? {
    var index = start
    while index < bytes.count, !Self.endsScalar(bytes[index]) { index += 1 }
    return index > start ? index : nil
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x20, 0x09, 0x0A, 0x0D: true
    default: false
    }
  }

  private static func endsScalar(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"): true
    default: isWhitespace(byte)
    }
  }

  private func decodeKey(_ range: Range<Int>) -> String? {
    let token = UnsafeRawBufferPointer(rebasing: bytes[range])
    if !token.contains(UInt8(ascii: "\\")) {
      return String(decoding: UnsafeRawBufferPointer(rebasing: token.dropFirst().dropLast()), as: UTF8.self)
    }
    return (try? JSONSerialization.jsonObject(with: Data(token), options: .fragmentsAllowed)) as? String
  }
}
