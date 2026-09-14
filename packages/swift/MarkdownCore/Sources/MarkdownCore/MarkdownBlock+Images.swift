import Foundation

extension MarkdownText {
  public var imageSources: [String] { spans.flatMap(\.imageSources) }
}

extension MarkdownSpan {
  public var imageSources: [String] {
    switch self {
    case let .image(_, source, _): [source]
    case let .emphasis(children), let .strong(children), let .strikethrough(children),
      let .link(children, _, _):
      children.flatMap(\.imageSources)
    default: []
    }
  }
}

extension MarkdownBlock {
  public var imageSources: [String] {
    switch self {
    case let .heading(_, text), let .paragraph(text): text.imageSources
    case let .bulletList(items): items.flatMap(\.imageSources)
    case let .orderedList(items): items.flatMap { $0.text.imageSources }
    case let .list(list): list.items.flatMap { $0.blocks.flatMap(\.imageSources) }
    case let .blockQuote(blocks): blocks.flatMap(\.imageSources)
    case let .table(headers, _, rows): (headers + rows.flatMap { $0 }).flatMap(\.imageSources)
    case .codeBlock, .thematicBreak: []
    }
  }
}
