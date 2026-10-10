/// Presentation-only detection for the one fact MD4C's public callbacks do not
/// expose: whether a fenced code block ended with a closing fence. The result
/// never influences Markdown structure.
enum FenceCompletionDetector {
  static func completions(in markdown: String) -> [Bool] {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    var result: [Bool] = []
    var index = 0
    while index < lines.count {
      guard let opening = openingFence(in: lines[index]) else {
        index += 1
        continue
      }
      let end = closingFenceEnd(in: lines, after: index, opening: opening)
      result.append(end != nil)
      index = end ?? lines.count
    }
    return result
  }

  private static func closingFenceEnd(
    in lines: [Substring], after index: Int,
    opening: (character: Character, length: Int)
  ) -> Int? {
    var cursor = index + 1
    while cursor < lines.count {
      if isClosingFence(lines[cursor], opening: opening) { return cursor + 1 }
      cursor += 1
    }
    return nil
  }

  private static func containerContent(_ line: Substring) -> Substring {
    var value = line
    while true {
      value = withoutContainerIndent(value)
      if value.first == ">" {
        value = value.dropFirst()
        if value.first == " " || value.first == "\t" { value = value.dropFirst() }
        continue
      }
      if let listContent = contentAfterListMarker(in: value) {
        value = listContent
        continue
      }
      return value
    }
  }

  private static func withoutContainerIndent(_ line: Substring) -> Substring {
    var value = line
    var spaces = 0
    while value.first == " ", spaces < 3 {
      value = value.dropFirst()
      spaces += 1
    }
    return value
  }

  /// Strips one CommonMark list marker. This scanner only annotates whether
  /// MD4C's fenced block is visually complete; MD4C remains authoritative
  /// for all container structure.
  private static func contentAfterListMarker(in line: Substring) -> Substring? {
    guard let first = line.first else { return nil }
    var remainder: Substring
    if "-*+".contains(first) {
      remainder = line.dropFirst()
    } else {
      let digits = line.prefix(while: { $0.isNumber })
      guard !digits.isEmpty, digits.count <= 9 else { return nil }
      remainder = line.dropFirst(digits.count)
      guard remainder.first == "." || remainder.first == ")" else { return nil }
      remainder = remainder.dropFirst()
    }

    let whitespace = remainder.prefix(while: { $0 == " " || $0 == "\t" })
    guard (1...4).contains(whitespace.count) else { return nil }
    return remainder.dropFirst(whitespace.count)
  }

  private static func openingFence(in line: Substring) -> (character: Character, length: Int)? {
    let value = containerContent(line)
    guard let character = value.first, character == "`" || character == "~" else { return nil }
    let length = value.prefix { $0 == character }.count
    guard length >= 3 else { return nil }
    if character == "`", value.dropFirst(length).contains("`") { return nil }
    return (character, length)
  }

  private static func isClosingFence(
    _ line: Substring,
    opening: (character: Character, length: Int)
  ) -> Bool {
    let value = containerContent(line)
    let run = value.prefix { $0 == opening.character }.count
    guard run >= opening.length else { return false }
    return value.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
  }
}
