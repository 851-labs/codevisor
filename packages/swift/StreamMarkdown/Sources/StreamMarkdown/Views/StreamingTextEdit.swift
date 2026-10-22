import Foundation

struct StreamingTextEdit: Equatable {
  let replaced: NSRange
  let replacement: NSRange
  let refreshedFade: NSRange?

  static func plan(from old: NSAttributedString, to new: NSAttributedString) -> StreamingTextEdit? {
    guard new.length >= old.length, (new.string as NSString).hasPrefix(old.string) else { return nil }
    let stable = firstLayoutDifference(between: old, and: new, before: old.length)
    return StreamingTextEdit(
      replaced: NSRange(location: stable, length: old.length - stable),
      replacement: NSRange(location: stable, length: new.length - stable),
      refreshedFade: fadeRange(in: old, new, before: stable)
    )
  }

  func apply(_ new: NSAttributedString, to storage: NSMutableAttributedString) {
    storage.beginEditing()
    storage.replaceCharacters(in: replaced, with: new.attributedSubstring(from: replacement))
    if let refreshedFade { Self.copyFade(from: new, in: refreshedFade, to: storage) }
    storage.endEditing()
  }

  private static func firstLayoutDifference(
    between old: NSAttributedString,
    and new: NSAttributedString,
    before limit: Int
  ) -> Int {
    var index = 0
    while index < limit {
      var oldRun = NSRange()
      var newRun = NSRange()
      let oldAttributes = old.attributes(at: index, effectiveRange: &oldRun)
      let newAttributes = new.attributes(at: index, effectiveRange: &newRun)
      guard layoutAttributes(oldAttributes) == layoutAttributes(newAttributes) else { return index }
      index = min(NSMaxRange(oldRun), NSMaxRange(newRun), limit)
    }
    return limit
  }

  private static func layoutAttributes(_ attributes: [NSAttributedString.Key: Any]) -> NSDictionary {
    var filtered = attributes
    filtered[.streamMarkdownFade] = nil
    return NSDictionary(dictionary: filtered)
  }

  private static func fadeRange(in old: NSAttributedString, _ new: NSAttributedString, before limit: Int) -> NSRange? {
    let starts = [firstFade(in: old, before: limit), firstFade(in: new, before: limit)].compactMap(\.self)
    guard let start = starts.min() else { return nil }
    return NSRange(location: start, length: limit - start)
  }

  private static func firstFade(in text: NSAttributedString, before limit: Int) -> Int? {
    var first: Int?
    text.enumerateAttribute(.streamMarkdownFade, in: NSRange(location: 0, length: limit)) { value, range, stop in
      guard value != nil else { return }
      first = range.location
      stop.pointee = true
    }
    return first
  }

  private static func copyFade(from new: NSAttributedString, in range: NSRange, to storage: NSMutableAttributedString) {
    storage.removeAttribute(.streamMarkdownFade, range: range)
    new.enumerateAttribute(.streamMarkdownFade, in: range) { value, run, _ in
      guard let value else { return }
      storage.addAttribute(.streamMarkdownFade, value: value, range: run)
    }
  }
}
