import CMD4C
import Foundation

extension MD4CParserContext {
  // MARK: C callbacks

  static let enterBlockCallback:
    @convention(c) (
      MD_BLOCKTYPE, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Int32 = { type, detail, userdata in
      guard let context = context(userdata) else { return 0 }

      // Nested block content terminates an implicit tight-list paragraph.
      if type != MD_BLOCK_DOC && type != MD_BLOCK_LI && type != MD_BLOCK_P {
        context.flushImplicitParagraph()
      }

      switch type {
      case MD_BLOCK_DOC:
        context.blockStack = [.document([])]
      case MD_BLOCK_QUOTE:
        context.blockStack.append(.quote([]))
      case MD_BLOCK_UL:
        let value = detail?.assumingMemoryBound(to: MD_BLOCK_UL_DETAIL.self).pointee
        context.blockStack.append(
          .list(
            isOrdered: false,
            start: 1,
            delimiter: character(value?.mark ?? MD_CHAR(45)),
            isTight: value?.is_tight != 0,
            items: []
          )
        )
      case MD_BLOCK_OL:
        let value = detail?.assumingMemoryBound(to: MD_BLOCK_OL_DETAIL.self).pointee
        context.blockStack.append(
          .list(
            isOrdered: true,
            start: Int(value?.start ?? 1),
            delimiter: character(value?.mark_delimiter ?? MD_CHAR(46)),
            isTight: value?.is_tight != 0,
            items: []
          )
        )
      case MD_BLOCK_LI:
        let value = detail?.assumingMemoryBound(to: MD_BLOCK_LI_DETAIL.self).pointee
        let mark = value?.task_mark ?? 0
        context.blockStack.append(
          .item(
            isTask: value?.is_task != 0,
            isChecked: mark == MD_CHAR(120) || mark == MD_CHAR(88),
            blocks: [],
            hasImplicitInline: false
          )
        )
      case MD_BLOCK_H:
        let level = detail?.assumingMemoryBound(to: MD_BLOCK_H_DETAIL.self).pointee.level ?? 1
        context.beginInline()
        context.blockStack.append(.heading(Int(level)))
      case MD_BLOCK_P:
        context.beginInline()
        context.blockStack.append(.paragraph)
      case MD_BLOCK_CODE:
        let value = detail?.assumingMemoryBound(to: MD_BLOCK_CODE_DETAIL.self).pointee
        let language = value.map { copiedAttribute($0.lang) }.flatMap { $0.isEmpty ? nil : $0 }
        let fence = value.flatMap { $0.fence_char == 0 ? nil : character($0.fence_char) }
        context.blockStack.append(
          .code(
            language: language,
            fence: fence,
            isComplete: context.completion(for: fence),
            pieces: []
          )
        )
      case MD_BLOCK_TABLE:
        context.blockStack.append(.table(headerRows: [], bodyRows: []))
      case MD_BLOCK_THEAD:
        context.tableSections.append(.header)
      case MD_BLOCK_TBODY:
        context.tableSections.append(.body)
      case MD_BLOCK_TR:
        context.blockStack.append(.row([]))
      case MD_BLOCK_TH, MD_BLOCK_TD:
        let rawAlignment = detail?.assumingMemoryBound(to: MD_BLOCK_TD_DETAIL.self).pointee.align
        let alignment: ColumnAlignment
        switch rawAlignment {
        case MD_ALIGN_LEFT: alignment = .leading
        case MD_ALIGN_CENTER: alignment = .center
        case MD_ALIGN_RIGHT: alignment = .trailing
        default: alignment = .none
        }
        context.beginInline()
        context.blockStack.append(.cell(alignment))
      case MD_BLOCK_HR, MD_BLOCK_HTML:
        break
      default:
        break
      }
      return 0
    }

  static let leaveBlockCallback:
    @convention(c) (
      MD_BLOCKTYPE, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Int32 = { type, _, userdata in
      guard let context = context(userdata) else { return 0 }

      switch type {
      case MD_BLOCK_QUOTE:
        guard case let .quote(blocks) = context.blockStack.popLast() else { return 0 }
        context.appendBlock(.blockQuote(blocks))
      case MD_BLOCK_UL, MD_BLOCK_OL:
        guard case let .list(isOrdered, start, delimiter, isTight, items) = context.blockStack.popLast()
        else { return 0 }
        context.appendBlock(
          context.makeListBlock(
            isOrdered: isOrdered,
            start: start,
            delimiter: delimiter,
            isTight: isTight,
            items: items
          ))
      case MD_BLOCK_LI:
        context.flushImplicitParagraph()
        guard case let .item(isTask, isChecked, blocks, _) = context.blockStack.popLast() else { return 0 }
        guard
          let listIndex = context.blockStack.lastIndex(where: {
            if case .list = $0 { return true }
            return false
          }),
          case let .list(isOrdered, start, delimiter, isTight, items) = context.blockStack[listIndex]
        else { return 0 }
        context.blockStack[listIndex] = .list(
          isOrdered: isOrdered,
          start: start,
          delimiter: delimiter,
          isTight: isTight,
          items: items + [MarkdownListItem(blocks: blocks, isTask: isTask, isChecked: isChecked)]
        )
      case MD_BLOCK_H:
        guard case let .heading(level) = context.blockStack.popLast() else { return 0 }
        context.appendBlock(.heading(level: level, text: context.endInlineRoot()))
      case MD_BLOCK_P:
        guard case .paragraph = context.blockStack.popLast() else { return 0 }
        context.appendBlock(.paragraph(context.endInlineRoot()))
      case MD_BLOCK_CODE:
        guard case let .code(language, _, isComplete, pieces) = context.blockStack.popLast() else { return 0 }
        var code = pieces.joined()
        if code.hasSuffix("\n") { code.removeLast() }
        context.appendBlock(.codeBlock(language: language, code: code, isComplete: isComplete))
      case MD_BLOCK_HR:
        context.appendBlock(.thematicBreak)
      case MD_BLOCK_TABLE:
        guard case let .table(headerRows, bodyRows) = context.blockStack.popLast() else { return 0 }
        let headers = headerRows.first ?? []
        let count = headers.count
        let normalizedRows = bodyRows.map { row -> [MarkdownText] in
          if row.count == count { return row }
          if row.count > count { return Array(row.prefix(count)) }
          return row + Array(repeating: MarkdownText(""), count: count - row.count)
        }
        let alignments = context.lastTableAlignments
        context.lastTableAlignments = []
        context.appendBlock(.table(headers: headers, alignments: alignments, rows: normalizedRows))
      case MD_BLOCK_THEAD, MD_BLOCK_TBODY:
        _ = context.tableSections.popLast()
      case MD_BLOCK_TR:
        guard case let .row(cells) = context.blockStack.popLast() else { return 0 }
        guard
          let tableIndex = context.blockStack.lastIndex(where: {
            if case .table = $0 { return true }
            return false
          }),
          case let .table(headerRows, bodyRows) = context.blockStack[tableIndex]
        else { return 0 }
        switch context.tableSections.last {
        case .header:
          context.blockStack[tableIndex] = .table(headerRows: headerRows + [cells], bodyRows: bodyRows)
        default:
          context.blockStack[tableIndex] = .table(headerRows: headerRows, bodyRows: bodyRows + [cells])
        }
      case MD_BLOCK_TH, MD_BLOCK_TD:
        guard case let .cell(alignment) = context.blockStack.popLast() else { return 0 }
        let text = context.endInlineRoot()
        guard
          let rowIndex = context.blockStack.lastIndex(where: {
            if case .row = $0 { return true }
            return false
          }), case let .row(cells) = context.blockStack[rowIndex]
        else { return 0 }
        context.blockStack[rowIndex] = .row(cells + [text])
        if context.tableSections.last == .header {
          context.lastTableAlignments.append(alignment)
        }
      case MD_BLOCK_DOC, MD_BLOCK_HTML:
        break
      default:
        break
      }
      return 0
    }

  static let enterSpanCallback:
    @convention(c) (
      MD_SPANTYPE, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Int32 = { type, detail, userdata in
      guard let context = context(userdata) else { return 0 }
      context.ensureTightListInlineRoot()
      let kind: InlineKind
      switch type {
      case MD_SPAN_EM: kind = .emphasis
      case MD_SPAN_STRONG: kind = .strong
      case MD_SPAN_DEL: kind = .strikethrough
      case MD_SPAN_CODE: kind = .code
      case MD_SPAN_A:
        let value = detail?.assumingMemoryBound(to: MD_SPAN_A_DETAIL.self).pointee
        kind = .link(
          destination: value.map { copiedAttribute($0.href) } ?? "",
          title: value.map { copiedAttribute($0.title) }.flatMap { $0.isEmpty ? nil : $0 }
        )
      case MD_SPAN_IMG:
        let value = detail?.assumingMemoryBound(to: MD_SPAN_IMG_DETAIL.self).pointee
        kind = .image(
          source: value.map { copiedAttribute($0.src) } ?? "",
          title: value.map { copiedAttribute($0.title) }.flatMap { $0.isEmpty ? nil : $0 }
        )
      default:
        // Optional MD4C extensions are disabled; preserve their visible
        // children if a future version nevertheless reports one.
        kind = .root
      }
      context.beginInline(kind)
      return 0
    }

  static let leaveSpanCallback:
    @convention(c) (
      MD_SPANTYPE, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Int32 = { _, _, userdata in
      guard let context = context(userdata), let state = context.inlineStack.popLast() else { return 0 }
      let span: MarkdownSpan?
      switch state.kind {
      case .root:
        span = nil
      case .emphasis:
        span = .emphasis(state.children)
      case .strong:
        span = .strong(state.children)
      case .strikethrough:
        span = .strikethrough(state.children)
      case .code:
        span = .code(state.children.map(\.plainText).joined())
      case let .link(destination, title):
        span = .link(children: state.children, destination: destination, title: title)
      case let .image(source, title):
        span = .image(alt: state.children, source: source, title: title)
      }
      if let span { context.appendSpan(span) } else { state.children.forEach(context.appendSpan) }
      return 0
    }

  static let textCallback:
    @convention(c) (
      MD_TEXTTYPE, UnsafePointer<MD_CHAR>?, MD_SIZE, UnsafeMutableRawPointer?
    ) -> Int32 = { type, pointer, size, userdata in
      guard let context = context(userdata) else { return 0 }
      var text = copiedText(pointer, size: size)

      if context.appendCodeText(text) { return 0 }
      context.ensureTightListInlineRoot()

      switch type {
      case MD_TEXT_NORMAL, MD_TEXT_CODE, MD_TEXT_HTML, MD_TEXT_LATEXMATH:
        context.appendSpan(.text(text))
      case MD_TEXT_NULLCHAR:
        context.appendSpan(.text("\u{FFFD}"))
      case MD_TEXT_BR:
        context.appendSpan(.hardBreak)
      case MD_TEXT_SOFTBR:
        context.appendSpan(.softBreak)
      case MD_TEXT_ENTITY:
        text = MarkdownEntityDecoder.decode(text)
        context.appendSpan(.text(text))
      default:
        context.appendSpan(.text(text))
      }
      return 0
    }
}
