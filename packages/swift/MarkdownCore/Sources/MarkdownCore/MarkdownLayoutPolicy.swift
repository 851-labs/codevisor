/// Bounds the synchronous text path. UTF-8 storage lengths avoid joining and
/// recounting rendered strings simply to choose a preparation strategy.
public enum MarkdownLayoutPolicy {
  public static let maximumSynchronousTextBytes = 16_384
  public static let maximumSynchronousTableRows = 64

  public static func requiresBackgroundTextLayout(_ blocks: [MarkdownBlock]) -> Bool {
    var remaining = maximumSynchronousTextBytes
    for block in blocks {
      remaining -= textBytes(block)
      if remaining < 0 { return true }
    }
    return false
  }

  private static func textBytes(_ block: MarkdownBlock) -> Int {
    switch block {
    case let .paragraph(text), let .heading(_, text): text.spans.reduce(0) { $0 + textBytes($1) }
    case let .bulletList(items): items.reduce(0) { $0 + $1.spans.reduce(0) { $0 + textBytes($1) } }
    case let .orderedList(items): items.reduce(0) { $0 + $1.text.spans.reduce(0) { $0 + textBytes($1) } }
    case let .list(list): list.items.reduce(0) { $0 + $1.blocks.reduce(0) { $0 + textBytes($1) } }
    case let .blockQuote(blocks): blocks.reduce(0) { $0 + textBytes($1) }
    case let .codeBlock(_, code, _): code.utf8.count
    case let .table(_, _, rows): rows.count > maximumSynchronousTableRows ? maximumSynchronousTextBytes + 1 : 0
    case .thematicBreak: 0
    }
  }

  private static func textBytes(_ span: MarkdownSpan) -> Int {
    switch span {
    case let .text(text), let .code(text): text.utf8.count
    case let .emphasis(children), let .strong(children), let .strikethrough(children),
      let .link(children, _, _), let .image(children, _, _):
      children.reduce(0) { $0 + textBytes($1) }
    case .softBreak, .hardBreak: 1
    }
  }
}
