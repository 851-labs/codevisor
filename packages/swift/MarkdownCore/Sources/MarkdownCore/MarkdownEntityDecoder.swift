import CMD4C
import Foundation

enum MarkdownEntityDecoder {
  static func decodeAll(_ string: String) -> String {
    guard string.contains("&") else { return string }
    var result = ""
    var cursor = string.startIndex
    while cursor < string.endIndex {
      guard let ampersand = string[cursor...].firstIndex(of: "&") else {
        result.append(contentsOf: string[cursor...])
        break
      }
      result.append(contentsOf: string[cursor..<ampersand])
      let searchEnd = string.index(ampersand, offsetBy: 50, limitedBy: string.endIndex) ?? string.endIndex
      guard let semicolon = string[ampersand..<searchEnd].firstIndex(of: ";") else {
        result.append("&")
        cursor = string.index(after: ampersand)
        continue
      }
      let afterSemicolon = string.index(after: semicolon)
      result.append(decode(String(string[ampersand..<afterSemicolon])))
      cursor = afterSemicolon
    }
    return result
  }

  static func decode(_ entity: String) -> String {
    guard entity.hasPrefix("&"), entity.hasSuffix(";") else { return entity }
    let body = String(entity.dropFirst().dropLast())
    if body.hasPrefix("#x") || body.hasPrefix("#X") {
      return scalar(String(body.dropFirst(2)), radix: 16) ?? entity
    }
    if body.hasPrefix("#") {
      return scalar(String(body.dropFirst()), radix: 10) ?? entity
    }
    return decodeNamed(entity)
  }

  private static func decodeNamed(_ entity: String) -> String {
    var value = entity
    return value.withUTF8 { bytes in
      guard let baseAddress = bytes.baseAddress,
        let match = entity_lookup(
          UnsafeRawPointer(baseAddress).assumingMemoryBound(to: CChar.self),
          bytes.count
        )
      else { return entity }
      let first = match.pointee.codepoints.0
      let second = match.pointee.codepoints.1
      guard let firstScalar = UnicodeScalar(first) else { return "\u{FFFD}" }
      var decoded = String(Character(firstScalar))
      if second != 0, let secondScalar = UnicodeScalar(second) {
        decoded.append(Character(secondScalar))
      }
      return decoded
    }
  }

  private static func scalar(_ value: String, radix: Int) -> String? {
    guard let number = UInt32(value, radix: radix),
      number != 0,
      !(0xD800...0xDFFF).contains(number),
      let scalar = UnicodeScalar(number)
    else { return "\u{FFFD}" }
    return String(Character(scalar))
  }
}
