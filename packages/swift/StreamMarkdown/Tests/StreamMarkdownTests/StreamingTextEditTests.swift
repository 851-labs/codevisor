import Foundation
import Testing

@testable import StreamMarkdown

struct StreamingTextEditTests {
  @Test func appendedTextReplacesOnlyTheTailAndRefreshesFadingWords() throws {
    let old = Self.text(("Hello ", nil), ("wor", Self.fade()))
    let new = Self.text(("Hello ", nil), ("world", Self.fade()), (" again", Self.fade()))

    let edit = try #require(StreamingTextEdit.plan(from: old, to: new))

    #expect(edit.replaced == NSRange(location: old.length, length: 0))
    #expect(edit.replacement == NSRange(location: old.length, length: new.length - old.length))
    #expect(edit.refreshedFade == NSRange(location: 6, length: 3))
    #expect(Self.applying(edit, from: old, to: new).isEqual(to: new))
  }

  @Test func restyledTailStartsTheEditAtTheFirstLayoutChange() throws {
    let old = Self.text(("Plain ", nil), ("**bold", nil))
    let new = NSMutableAttributedString(attributedString: Self.text(("Plain ", nil), ("**bold** text", nil)))
    new.addAttribute(.underlineStyle, value: 1, range: NSRange(location: 6, length: 8))

    let edit = try #require(StreamingTextEdit.plan(from: old, to: new))

    #expect(edit.replaced.location == 6)
    #expect(edit.refreshedFade == nil)
    #expect(Self.applying(edit, from: old, to: new).isEqual(to: new))
  }

  @Test func rewrittenPrefixFallsBackToFullReplacement() {
    let old = Self.text(("1. first", nil))
    let new = Self.text(("2. first and more", nil))

    #expect(StreamingTextEdit.plan(from: old, to: new) == nil)
  }

  private static func applying(
    _ edit: StreamingTextEdit, from old: NSAttributedString, to new: NSAttributedString
  )
    -> NSAttributedString
  {
    let storage = NSMutableAttributedString(attributedString: old)
    edit.apply(new, to: storage)
    return storage
  }

  private static func fade() -> StreamingTextFadeMetadata {
    StreamingTextFadeMetadata(startTime: 1)
  }

  private static func text(_ runs: (String, StreamingTextFadeMetadata?)...) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for (string, fade) in runs {
      var attributes: [NSAttributedString.Key: Any] = [:]
      attributes[.streamMarkdownFade] = fade
      result.append(NSAttributedString(string: string, attributes: attributes))
    }
    return result
  }
}
