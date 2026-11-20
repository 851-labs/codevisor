#if canImport(AppKit)
  import AppKit

  final class MarkdownTableTypesetter: NSATSTypesetter {
    static func install(on layoutManager: NSLayoutManager) {
      layoutManager.typesetter = MarkdownTableTypesetter()
    }

    override func layoutCharacters(
      in characterRange: NSRange, for layoutManager: NSLayoutManager, maximumNumberOfLineFragments maxNumLines: Int
    ) -> NSRange {
      super.layoutCharacters(
        in: Self.firstCell(of: characterRange, in: layoutManager), for: layoutManager,
        maximumNumberOfLineFragments: maxNumLines)
    }

    private static func firstCell(of range: NSRange, in layoutManager: NSLayoutManager) -> NSRange {
      guard range.length > 0, let string = layoutManager.textStorage?.string as NSString?,
        range.location < string.length
      else { return range }
      let cell = string.paragraphRange(for: NSRange(location: range.location, length: 0))
      return NSIntersectionRange(range, cell)
    }
  }
#endif
