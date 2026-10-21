public enum MarkdownFrontmatter {
  public static func removing(from text: String) -> Substring {
    let body = text.hasPrefix("\u{FEFF}") ? text.dropFirst() : Substring(text)
    guard body.hasPrefix("---") else { return Substring(text) }

    let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard isOpeningFence(lines[0]) else { return Substring(text) }
    guard let closing = lines.dropFirst().first(where: isClosingFence) else { return Substring(text) }

    return body[closing.endIndex...].dropFirst()
  }

  private static func isOpeningFence(_ line: Substring) -> Bool {
    line.wholeMatch(of: /---[ \t]*/) != nil
  }

  private static func isClosingFence(_ line: Substring) -> Bool {
    line.wholeMatch(of: /(---|\.\.\.)[ \t]*/) != nil
  }
}
