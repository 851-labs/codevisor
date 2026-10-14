import CMD4C
import Foundation

final class MD4CParserContext {
  final class Children<Element>: ExpressibleByArrayLiteral {
    var values: [Element]

    init(arrayLiteral elements: Element...) { values = elements }
  }

  enum BlockState {
    case document(Children<MarkdownBlock>)
    case quote(Children<MarkdownBlock>)
    case list(isOrdered: Bool, start: Int, delimiter: Character, isTight: Bool, items: Children<MarkdownListItem>)
    case item(isTask: Bool, isChecked: Bool, blocks: Children<MarkdownBlock>, hasImplicitInline: Bool)
    case paragraph
    case heading(Int)
    case code(language: String?, fence: Character?, isComplete: Bool, pieces: Children<String>)
    case table(headerRows: Children<[MarkdownText]>, bodyRows: Children<[MarkdownText]>)
    case row(Children<MarkdownText>)
    case cell(ColumnAlignment)

    var acceptsBlocks: Bool {
      switch self {
      case .document, .quote, .item: true
      default: false
      }
    }
  }

  enum InlineKind {
    case root
    case emphasis
    case strong
    case strikethrough
    case code
    case link(destination: String, title: String?)
    case image(source: String, title: String?)
  }

  struct InlineState {
    let kind: InlineKind
    var children: [MarkdownSpan]
  }

  enum TableSection { case header, body }

  var blockStack: [BlockState] = []
  var inlineStack: [InlineState] = []
  var tableSections: [TableSection] = []
  var tableByteRanges: [Range<Int>] = []
  var sourceBytes: UnsafeBufferPointer<UInt8>?
  var pendingSourceBlockOrdinal: Int?
  var reusableBlockCount = 0
  var reparseStart = 0
  private let fenceCompletions: [Bool]
  private var nextFenceCompletion = 0

  init(fenceCompletions: [Bool]) {
    self.fenceCompletions = fenceCompletions
  }

  var blocks: [MarkdownBlock] {
    guard case let .document(blocks) = blockStack.first else { return [] }
    return blocks.values
  }

  func noteTextSource(_ pointer: UnsafePointer<MD_CHAR>?) {
    guard let ordinal = pendingSourceBlockOrdinal,
      let pointer, let bytes = sourceBytes, let base = bytes.baseAddress
    else { return }
    let offset = Int(bitPattern: pointer) - Int(bitPattern: base)
    guard offset >= 0, offset < bytes.count else { return }
    pendingSourceBlockOrdinal = nil
    var lineStart = offset
    while lineStart > 0, bytes[lineStart - 1] != 10, bytes[lineStart - 1] != 13 {
      lineStart -= 1
    }
    guard lineStart > 0 else { return }
    reusableBlockCount = ordinal
    reparseStart = lineStart
  }

  func beginInline(_ kind: InlineKind = .root) {
    inlineStack.append(InlineState(kind: kind, children: []))
  }

  func appendSpan(_ span: MarkdownSpan) {
    guard let index = inlineStack.indices.last else { return }
    inlineStack[index].children.append(span)
  }

  func endInlineRoot() -> MarkdownText {
    guard let state = inlineStack.popLast() else { return MarkdownText("") }
    return MarkdownText(spans: state.children)
  }

  func appendBlock(_ block: MarkdownBlock) {
    guard let index = blockStack.lastIndex(where: \.acceptsBlocks) else { return }
    switch blockStack[index] {
    case let .document(blocks), let .quote(blocks), let .item(_, _, blocks, _):
      blocks.values.append(block)
    default:
      break
    }
  }

  func ensureTightListInlineRoot() {
    guard inlineStack.isEmpty,
      let itemIndex = blockStack.lastIndex(where: {
        if case .item = $0 { return true }
        return false
      }),
      let listIndex = blockStack[..<itemIndex].lastIndex(where: {
        if case .list = $0 { return true }
        return false
      }),
      case let .list(_, _, _, isTight, _) = blockStack[listIndex], isTight,
      case let .item(isTask, isChecked, blocks, _) = blockStack[itemIndex]
    else { return }

    beginInline()
    blockStack[itemIndex] = .item(
      isTask: isTask,
      isChecked: isChecked,
      blocks: blocks,
      hasImplicitInline: true
    )
  }

  func flushImplicitParagraph() {
    guard
      let itemIndex = blockStack.lastIndex(where: {
        if case .item = $0 { return true }
        return false
      }),
      case let .item(isTask, isChecked, blocks, hasImplicitInline) = blockStack[itemIndex],
      hasImplicitInline
    else { return }

    let text = endInlineRoot()
    if !text.spans.isEmpty { blocks.values.append(.paragraph(text)) }
    blockStack[itemIndex] = .item(
      isTask: isTask,
      isChecked: isChecked,
      blocks: blocks,
      hasImplicitInline: false
    )
  }

  func appendCodeText(_ text: String) -> Bool {
    guard
      let index = blockStack.lastIndex(where: {
        if case .code = $0 { return true }
        return false
      }),
      case let .code(_, _, _, pieces) = blockStack[index]
    else { return false }
    pieces.values.append(text)
    return true
  }

  func completion(for fence: Character?) -> Bool {
    guard fence != nil else { return true }
    defer { nextFenceCompletion += 1 }
    guard nextFenceCompletion < fenceCompletions.count else { return true }
    return fenceCompletions[nextFenceCompletion]
  }

  static func context(_ userdata: UnsafeMutableRawPointer?) -> MD4CParserContext? {
    userdata.map { Unmanaged<MD4CParserContext>.fromOpaque($0).takeUnretainedValue() }
  }

  static func character(_ value: MD_CHAR) -> Character {
    Character(UnicodeScalar(UInt8(bitPattern: value)))
  }

  static func copiedText(_ pointer: UnsafePointer<MD_CHAR>?, size: MD_SIZE) -> String {
    guard let pointer, size > 0 else { return "" }
    let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(size)), as: UTF8.self)
  }

  static func copiedAttribute(_ attribute: MD_ATTRIBUTE) -> String {
    MarkdownEntityDecoder.decodeAll(copiedText(attribute.text, size: attribute.size))
  }

  var lastTableAlignments: [ColumnAlignment] {
    get { tableAlignmentsStack.last ?? [] }
    set {
      if tableAlignmentsStack.isEmpty {
        tableAlignmentsStack.append(newValue)
      } else {
        tableAlignmentsStack[tableAlignmentsStack.count - 1] = newValue
      }
    }
  }
  private var tableAlignmentsStack: [[ColumnAlignment]] = [[]]

  func makeListBlock(
    isOrdered: Bool,
    start: Int,
    delimiter: Character,
    isTight: Bool,
    items: [MarkdownListItem]
  ) -> MarkdownBlock {
    let simpleTexts = Self.simpleListTexts(items)
    if isTight, let simpleTexts {
      return Self.simpleListBlock(simpleTexts, isOrdered: isOrdered, start: start)
    }
    return .list(
      MarkdownList(
        isOrdered: isOrdered,
        start: start,
        delimiter: delimiter,
        isTight: isTight,
        items: items
      ))
  }

  private static func simpleListTexts(_ items: [MarkdownListItem]) -> [MarkdownText]? {
    return items.reduce(into: []) { result, item in
      guard !item.isTask else { result = nil; return }
      if item.blocks.isEmpty {
        result?.append(MarkdownText(spans: []))
        return
      }
      guard item.blocks.count == 1,
        case let .paragraph(text) = item.blocks[0]
      else { result = nil; return }
      result?.append(text)
    }
  }

  private static func simpleListBlock(
    _ simpleTexts: [MarkdownText], isOrdered: Bool, start: Int
  ) -> MarkdownBlock {
    if isOrdered {
      return .orderedList(
        simpleTexts.enumerated().map {
          OrderedListItem(number: start + $0.offset, text: $0.element)
        })
    }
    return .bulletList(simpleTexts)
  }
}
