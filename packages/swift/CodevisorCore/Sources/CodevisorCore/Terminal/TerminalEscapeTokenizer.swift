import Foundation

/// Splits terminal text into characters and whole escape sequences without
/// owning prediction state or the output scanner’s carried mode-sequence tail.
enum TerminalEscapeTokenizer {
  enum Token {
    case character(Character)
    case escapeSequence
  }

  /// Splits text into characters and whole escape sequences (CSI, OSC, and
  /// two-character escapes). An unfinished sequence at the end counts as one.
  static func tokens(_ text: String) -> [Token] {
    var tokens: [Token] = []
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      index = text.index(after: index)
      guard character == "\u{1B}" else {
        tokens.append(.character(character))
        continue
      }
      tokens.append(.escapeSequence)
      consumeEscape(in: text, at: &index)
    }
    return tokens
  }

  private static func consumeEscape(in text: String, at index: inout String.Index) {
    guard index < text.endIndex else { return }
    let kind = text[index]
    index = text.index(after: index)
    if kind == "[" {
      consumeCSI(in: text, at: &index)
    } else if kind == "]" || kind == "P" || kind == "_" {
      consumeControlString(in: text, at: &index)
    }
  }

  private static func consumeCSI(in text: String, at index: inout String.Index) {
    // CSI: parameters and intermediates, then a final byte @...~.
    while index < text.endIndex {
      let scalar = text[index].unicodeScalars.first!.value
      index = text.index(after: index)
      if (0x40...0x7E).contains(scalar) { break }
    }
  }

  private static func consumeControlString(in text: String, at index: inout String.Index) {
    // OSC / DCS / APC: until BEL or ST (ESC \).
    while index < text.endIndex {
      let next = text[index]
      index = text.index(after: index)
      if next == "\u{07}" { break }
      if next == "\u{1B}", index < text.endIndex, text[index] == "\\" {
        index = text.index(after: index)
        break
      }
    }
  }
}
