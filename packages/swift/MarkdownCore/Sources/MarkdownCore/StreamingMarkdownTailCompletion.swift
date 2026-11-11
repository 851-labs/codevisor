import Foundation

enum StreamingMarkdownTailCompletion {
  private enum Opener {
    case code(start: Int, length: Int)
    case strong(start: Int)
    case strike(start: Int)
    case linkText(start: Int, isImage: Bool)
    case linkLabel(start: Int, isImage: Bool)
    case linkDestination(start: Int, isImage: Bool)
    case partialMarker(start: Int)
  }

  private struct Ending {
    var keptByteCount: Int
    var closers: [String] = []
  }

  private static let backtick = UInt8(ascii: "`")
  private static let backslash = UInt8(ascii: "\\")
  private static let asterisk = UInt8(ascii: "*")
  private static let tilde = UInt8(ascii: "~")
  private static let bang = UInt8(ascii: "!")
  private static let openBracket = UInt8(ascii: "[")
  private static let closeBracket = UInt8(ascii: "]")
  private static let openParen = UInt8(ascii: "(")
  private static let closeParen = UInt8(ascii: ")")
  private static let newline = UInt8(ascii: "\n")
  private static let space = UInt8(ascii: " ")
  private static let tab = UInt8(ascii: "\t")

  static func completed(_ markdown: String) -> String {
    let bytes = Array(markdown.utf8)
    guard !endsInsideFence(bytes) else { return markdown }

    let start = lastParagraphStart(bytes)
    let openers = unclosedOpeners(in: bytes, from: start)
    guard !openers.isEmpty else { return markdown }

    let ending = ending(closing: openers, in: bytes)
    let keptCount = trimmedLength(bytes, upTo: ending.keptByteCount, before: ending.closers.first)
    let kept = String(decoding: bytes.prefix(keptCount), as: UTF8.self)
    return kept + ending.closers.joined()
  }

  private static func trimmedLength(_ bytes: [UInt8], upTo count: Int, before closer: String?) -> Int {
    guard closer == "**" || closer == "~~" else { return count }

    var length = count
    while length > 0, bytes[length - 1] == space || bytes[length - 1] == tab { length -= 1 }
    return length
  }

  private static func ending(closing openers: [Opener], in bytes: [UInt8]) -> Ending {
    var ending = Ending(keptByteCount: bytes.count)
    for opener in openers.reversed() {
      if let start = droppedStart(of: opener, byteCount: ending.keptByteCount) {
        ending = Ending(keptByteCount: start)
        continue
      }
      if case let .linkText(start, _) = opener {
        let label = bytes[(start + 1)..<ending.keptByteCount]
        if label.isEmpty {
          ending = Ending(keptByteCount: start)
          continue
        }
        if !looksLikeLinkLabel(label) { continue }
      }
      ending.closers.append(closer(for: opener))
    }
    return ending
  }

  private static func droppedStart(of opener: Opener, byteCount: Int) -> Int? {
    switch opener {
    case let .code(start, length): start + length == byteCount ? start : nil
    case let .strong(start), let .strike(start): start + 2 == byteCount ? start : nil
    case let .linkText(start, isImage), let .linkLabel(start, isImage), let .linkDestination(start, isImage):
      isImage ? start : nil
    case let .partialMarker(start): start
    }
  }

  private static func closer(for opener: Opener) -> String {
    switch opener {
    case let .code(_, length): String(repeating: "`", count: length)
    case .strong: "**"
    case .strike: "~~"
    case .linkText: "]()"
    case .linkLabel: "()"
    case .linkDestination: ")"
    case .partialMarker: ""
    }
  }

  private static func unclosedOpeners(in bytes: [UInt8], from start: Int) -> [Opener] {
    var openers: [Opener] = []
    var index = start
    while index < bytes.count {
      let byte = bytes[index]
      if case let .code(_, length)? = openers.last {
        index = scanInsideCode(bytes, at: index, length: length, openers: &openers)
        continue
      }
      if byte == backslash {
        index += 2
        continue
      }
      if case .linkDestination? = openers.last {
        if byte == closeParen { openers.removeLast() }
        index += 1
        continue
      }
      index = scanMarker(bytes, at: index, openers: &openers)
    }
    return openers
  }

  private static func scanInsideCode(_ bytes: [UInt8], at index: Int, length: Int, openers: inout [Opener]) -> Int {
    guard bytes[index] == backtick else { return index + 1 }

    let run = runLength(of: backtick, in: bytes, at: index)
    if run == length { openers.removeLast() }
    return index + run
  }

  private static func scanMarker(_ bytes: [UInt8], at index: Int, openers: inout [Opener]) -> Int {
    let byte = bytes[index]
    switch byte {
    case backtick:
      let run = runLength(of: backtick, in: bytes, at: index)
      openers.append(.code(start: index, length: run))
      return index + run
    case asterisk where next(bytes, index) == asterisk:
      toggle(.strong(start: index), in: &openers)
      return index + 2
    case tilde where next(bytes, index) == tilde:
      toggle(.strike(start: index), in: &openers)
      return index + 2
    case asterisk where index + 1 == bytes.count, tilde where index + 1 == bytes.count:
      openers.append(.partialMarker(start: index))
      return index + 1
    case bang where next(bytes, index) == openBracket && startsLinkText(bytes, at: index):
      openers.append(.linkText(start: index, isImage: true))
      return index + 2
    case openBracket where startsLinkText(bytes, at: index):
      openers.append(.linkText(start: index, isImage: false))
      return index + 1
    case closeBracket:
      return closeLinkText(bytes, at: index, openers: &openers)
    default:
      return index + 1
    }
  }

  private static func closeLinkText(_ bytes: [UInt8], at index: Int, openers: inout [Opener]) -> Int {
    guard let position = openers.lastIndex(where: { if case .linkText = $0 { true } else { false } }),
      case let .linkText(start, isImage) = openers[position]
    else { return index + 1 }

    openers.removeSubrange(position...)
    if next(bytes, index) == openParen {
      openers.append(.linkDestination(start: start, isImage: isImage))
      return index + 2
    }
    if index + 1 == bytes.count, isImage || looksLikeLinkLabel(bytes[(start + 1)..<index]) {
      openers.append(.linkLabel(start: start, isImage: isImage))
    }
    return index + 1
  }

  private static func looksLikeLinkLabel(_ label: ArraySlice<UInt8>) -> Bool {
    let letters = label.filter { (65...90).contains($0) || (97...122).contains($0) || $0 >= 0x80 }
    return !letters.isEmpty
      && !(label.count == 1 && (label.first == UInt8(ascii: "x") || label.first == UInt8(ascii: "X")))
  }

  private static func toggle(_ marker: Opener, in openers: inout [Opener]) {
    if let position = openers.lastIndex(where: { sameMarker($0, marker) }) {
      openers.remove(at: position)
    } else {
      openers.append(marker)
    }
  }

  private static func sameMarker(_ lhs: Opener, _ rhs: Opener) -> Bool {
    switch (lhs, rhs) {
    case (.strong, .strong), (.strike, .strike): true
    default: false
    }
  }

  private static func startsLinkText(_ bytes: [UInt8], at index: Int) -> Bool {
    guard index > 0 else { return true }

    let previous = bytes[index - 1]
    return !isWordByte(previous)
  }

  private static func isWordByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
  }

  private static func next(_ bytes: [UInt8], _ index: Int) -> UInt8? {
    index + 1 < bytes.count ? bytes[index + 1] : nil
  }

  private static func runLength(of byte: UInt8, in bytes: [UInt8], at index: Int) -> Int {
    var end = index
    while end < bytes.count, bytes[end] == byte { end += 1 }
    return end - index
  }

  private static func lastParagraphStart(_ bytes: [UInt8]) -> Int {
    var index = bytes.count - 1
    while index > 0 {
      if bytes[index] == newline, bytes[index - 1] == newline { return index + 1 }
      index -= 1
    }
    return 0
  }

  private static func endsInsideFence(_ bytes: [UInt8]) -> Bool {
    var inside = false
    var lineStart = 0
    while lineStart < bytes.count {
      var lineEnd = lineStart
      while lineEnd < bytes.count, bytes[lineEnd] != newline { lineEnd += 1 }
      if isFenceLine(bytes[lineStart..<lineEnd]) { inside.toggle() }
      lineStart = lineEnd + 1
    }
    return inside
  }

  private static func isFenceLine(_ line: ArraySlice<UInt8>) -> Bool {
    let trimmed = line.drop { $0 == UInt8(ascii: " ") }
    return trimmed.starts(with: [backtick, backtick, backtick]) || trimmed.starts(with: Array("~~~".utf8))
  }
}
