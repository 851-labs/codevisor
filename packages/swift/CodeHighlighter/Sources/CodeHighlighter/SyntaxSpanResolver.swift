import Foundation

/// Clips overlapping captures, selects their winning styles, and joins adjacent equal spans.
enum SyntaxSpanResolver {
  private struct Event { let offset: Int; let index: Int; let start: Bool }

  static func resolve(
    _ syntax: [SyntaxSpan], in range: NSRange,
    style: (SyntaxSpan) -> CodeHighlightDocument.Style
  ) -> [CodeHighlightDocument.Span] {
    let events = events(syntax, in: range)
    var active = Set<Int>()
    var result: [CodeHighlightDocument.Span] = []
    var previous = range.location
    for event in events {
      if event.offset > previous,
        let winner = active.max(by: { precedes($0, $1, in: syntax) })
      {
        let resolved = style(syntax[winner])
        append(resolved, from: previous, to: event.offset, into: &result)
      }
      if event.start { active.insert(event.index) } else { active.remove(event.index) }
      previous = event.offset
    }
    return result
  }

  private static func events(_ syntax: [SyntaxSpan], in range: NSRange) -> [Event] {
    var events: [Event] = []
    for (index, span) in syntax.enumerated() {
      let clipped = NSIntersectionRange(range, span.range)
      if clipped.length > 0 {
        events.append(Event(offset: clipped.location, index: index, start: true))
        events.append(Event(offset: NSMaxRange(clipped), index: index, start: false))
      }
    }
    events.sort { $0.offset < $1.offset }
    return events
  }

  private static func precedes(_ left: Int, _ right: Int, in syntax: [SyntaxSpan]) -> Bool {
    if syntax[left].priority != syntax[right].priority { return syntax[left].priority < syntax[right].priority }
    if syntax[left].range.length != syntax[right].range.length {
      return syntax[left].range.length > syntax[right].range.length
    }
    let leftSpecificity = syntax[left].capture.split(separator: ".").count
    let rightSpecificity = syntax[right].capture.split(separator: ".").count
    if leftSpecificity != rightSpecificity { return leftSpecificity < rightSpecificity }
    if syntax[left].order != syntax[right].order { return syntax[left].order < syntax[right].order }
    return left < right
  }

  private static func append(
    _ resolved: CodeHighlightDocument.Style, from previous: Int, to offset: Int,
    into result: inout [CodeHighlightDocument.Span]
  ) {
    if let last = result.last, last.style == resolved, NSMaxRange(last.range) == previous {
      result[result.count - 1] = CodeHighlightDocument.Span(
        range: NSRange(location: last.range.location, length: offset - last.range.location), style: resolved)
    } else {
      result.append(
        CodeHighlightDocument.Span(range: NSRange(location: previous, length: offset - previous), style: resolved))
    }
  }
}
