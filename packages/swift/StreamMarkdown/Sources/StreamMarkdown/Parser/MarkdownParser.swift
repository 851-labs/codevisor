import CMD4C
import Foundation

/// Parses CommonMark plus the MD4C GitHub extensions into Codevisor's semantic
/// render model. MD4C is the only component that decides block and span
/// structure; this type only copies callback data into memory-safe Swift values.
public struct MarkdownParser: Sendable {
    public init() {}

    public func parse(_ markdown: String) -> [MarkdownBlock] {
        guard !markdown.isEmpty else { return [] }
        guard markdown.utf8.count <= Int(UInt32.max) else {
            return [.paragraph(MarkdownText(markdown))]
        }

        let context = MD4CParserContext(
            fenceCompletions: FenceCompletionDetector.completions(in: markdown)
        )
        var input = markdown
        let result: Int32 = input.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var parser = MD_PARSER()
            parser.abi_version = 0
            parser.flags =
                UInt32(MD_FLAG_PERMISSIVEURLAUTOLINKS)
                | UInt32(MD_FLAG_PERMISSIVEEMAILAUTOLINKS)
                | UInt32(MD_FLAG_PERMISSIVEWWWAUTOLINKS)
                | UInt32(MD_FLAG_TABLES)
                | UInt32(MD_FLAG_STRIKETHROUGH)
                | UInt32(MD_FLAG_TASKLISTS)
                | UInt32(MD_FLAG_NOHTMLBLOCKS)
                | UInt32(MD_FLAG_NOHTMLSPANS)
            parser.enter_block = MD4CParserContext.enterBlockCallback
            parser.leave_block = MD4CParserContext.leaveBlockCallback
            parser.enter_span = MD4CParserContext.enterSpanCallback
            parser.leave_span = MD4CParserContext.leaveSpanCallback
            parser.text = MD4CParserContext.textCallback
            parser.debug_log = nil
            parser.syntax = nil

            return md_parse(
                UnsafeRawPointer(baseAddress).assumingMemoryBound(to: MD_CHAR.self),
                MD_SIZE(bytes.count),
                &parser,
                Unmanaged.passUnretained(context).toOpaque()
            )
        }

        guard result == 0 else {
            return markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [.paragraph(MarkdownText(markdown))]
        }
        return context.blocks
    }

    /// Parses an inline fragment with the same MD4C configuration used for
    /// complete documents. Production rendering normally receives spans from
    /// the original document parse; this is retained for public callers and
    /// isolated renderer tests.
    public func parseInline(_ markdown: String) -> MarkdownText {
        let blocks = parse(markdown)
        if blocks.count == 1 {
            switch blocks[0] {
            case let .paragraph(text), let .heading(_, text): return text
            default: break
            }
        }
        return MarkdownText(markdown)
    }
}

final class MD4CParserContext {
    enum BlockState {
        case document([MarkdownBlock])
        case quote([MarkdownBlock])
        case list(isOrdered: Bool, start: Int, delimiter: Character, isTight: Bool, items: [MarkdownListItem])
        case item(isTask: Bool, isChecked: Bool, blocks: [MarkdownBlock], hasImplicitInline: Bool)
        case paragraph
        case heading(Int)
        case code(language: String?, fence: Character?, isComplete: Bool, pieces: [String])
        case table(headerRows: [[MarkdownText]], bodyRows: [[MarkdownText]])
        case row([MarkdownText])
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
    private let fenceCompletions: [Bool]
    private var nextFenceCompletion = 0

    init(fenceCompletions: [Bool]) {
        self.fenceCompletions = fenceCompletions
    }

    var blocks: [MarkdownBlock] {
        guard case let .document(blocks) = blockStack.first else { return [] }
        return blocks
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
        case let .document(blocks):
            blockStack[index] = .document(blocks + [block])
        case let .quote(blocks):
            blockStack[index] = .quote(blocks + [block])
        case let .item(isTask, isChecked, blocks, hasImplicitInline):
            blockStack[index] = .item(
                isTask: isTask,
                isChecked: isChecked,
                blocks: blocks + [block],
                hasImplicitInline: hasImplicitInline
            )
        default:
            break
        }
    }

    /// MD4C omits paragraph enter/leave callbacks inside tight lists. Start an
    /// implicit paragraph when its first inline callback arrives.
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
        let nextBlocks = text.spans.isEmpty ? blocks : blocks + [.paragraph(text)]
        blockStack[itemIndex] = .item(
            isTask: isTask,
            isChecked: isChecked,
            blocks: nextBlocks,
            hasImplicitInline: false
        )
    }

    func appendCodeText(_ text: String) -> Bool {
        guard
            let index = blockStack.lastIndex(where: {
                if case .code = $0 { return true }
                return false
            }),
            case let .code(language, fence, isComplete, pieces) = blockStack[index]
        else { return false }
        blockStack[index] = .code(
            language: language,
            fence: fence,
            isComplete: isComplete,
            pieces: pieces + [text]
        )
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
        let simpleTexts: [MarkdownText]? = items.reduce(into: []) { result, item in
            guard !item.isTask, item.blocks.count == 1,
                case let .paragraph(text) = item.blocks[0]
            else { result = nil; return }
            result?.append(text)
        }
        if isTight, let simpleTexts {
            if isOrdered {
                return .orderedList(
                    simpleTexts.enumerated().map {
                        OrderedListItem(number: start + $0.offset, text: $0.element)
                    })
            }
            return .bulletList(simpleTexts)
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
}

/// Presentation-only detection for the one fact MD4C's public callbacks do not
/// expose: whether a fenced code block ended with a closing fence. The result
/// never influences Markdown structure.
private enum FenceCompletionDetector {
    static func completions(in markdown: String) -> [Bool] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [Bool] = []
        var index = 0
        while index < lines.count {
            guard let opening = openingFence(in: lines[index]) else {
                index += 1
                continue
            }
            var cursor = index + 1
            var isClosed = false
            while cursor < lines.count {
                if isClosingFence(lines[cursor], opening: opening) {
                    isClosed = true
                    cursor += 1
                    break
                }
                cursor += 1
            }
            result.append(isClosed)
            index = cursor
        }
        return result
    }

    private static func containerContent(_ line: Substring) -> Substring {
        var value = line
        while true {
            var spaces = 0
            while value.first == " ", spaces < 3 {
                value = value.dropFirst()
                spaces += 1
            }
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

enum MarkdownEntityDecoder {
    static func decodeAll(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        var cursor = string.startIndex
        while cursor < string.endIndex {
            guard let ampersand = string[cursor...].firstIndex(of: "&") else {
                result.append(contentsOf: string[cursor...])
                break
            }
            result.append(contentsOf: string[cursor..<ampersand])
            let searchEnd = string.index(ampersand, offsetBy: 50, limitedBy: string.endIndex) ?? string.endIndex
            guard let semicolon = string[ampersand..<searchEnd].firstIndex(of: ";") else {
                result.append("&")
                cursor = string.index(after: ampersand)
                continue
            }
            let afterSemicolon = string.index(after: semicolon)
            result.append(decode(String(string[ampersand..<afterSemicolon])))
            cursor = afterSemicolon
        }
        return result
    }

    static func decode(_ entity: String) -> String {
        guard entity.hasPrefix("&"), entity.hasSuffix(";") else { return entity }
        let body = String(entity.dropFirst().dropLast())
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return scalar(String(body.dropFirst(2)), radix: 16) ?? entity
        }
        if body.hasPrefix("#") {
            return scalar(String(body.dropFirst()), radix: 10) ?? entity
        }
        var value = entity
        return value.withUTF8 { bytes in
            guard let baseAddress = bytes.baseAddress,
                let match = entity_lookup(
                    UnsafeRawPointer(baseAddress).assumingMemoryBound(to: CChar.self),
                    bytes.count
                )
            else { return entity }
            let first = match.pointee.codepoints.0
            let second = match.pointee.codepoints.1
            guard let firstScalar = UnicodeScalar(first) else { return "\u{FFFD}" }
            var decoded = String(Character(firstScalar))
            if second != 0, let secondScalar = UnicodeScalar(second) {
                decoded.append(Character(secondScalar))
            }
            return decoded
        }
    }

    private static func scalar(_ value: String, radix: Int) -> String? {
        guard let number = UInt32(value, radix: radix),
            number != 0,
            !(0xD800...0xDFFF).contains(number),
            let scalar = UnicodeScalar(number)
        else { return "\u{FFFD}" }
        return String(Character(scalar))
    }
}
