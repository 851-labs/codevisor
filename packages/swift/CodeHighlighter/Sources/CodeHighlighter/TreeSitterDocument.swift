import CTreeSitter
import Foundation

struct SyntaxSpan: Equatable, Sendable {
  let range: NSRange
  let capture: String
  let language: String
  let priority: Int
  let order: Int
}

/// Mutable C handles never leave the actor that owns this document.
final class TreeSitterDocument {
  let grammar: TreeSitterGrammar
  private let parser: OpaquePointer
  private(set) var tree: OpaquePointer?
  private(set) var text: TreeSitterText
  private(set) var parseCount = 0
  private struct Child {
    var range: NSRange
    let document: TreeSitterDocument
  }
  private var children: [Child] = []
  private var needsParse = true
  private var localReferencesCache: Set<Int>?

  init(source: String, language: String) throws {
    grammar = try TreeSitterGrammar.load(language)
    guard let parser = ts_parser_new() else { throw TreeSitterError.parse }
    guard ts_parser_set_language(parser, grammar.language) else {
      ts_parser_delete(parser)
      throw TreeSitterError.unavailable(language)
    }
    self.parser = parser
    text = TreeSitterText(source)
  }

  deinit {
    if let tree { ts_tree_delete(tree) }
    ts_parser_delete(parser)
  }

  func apply(_ edit: CodeHighlightDocument.Edit) throws -> NSRange {
    // Root-scope bindings may change builtin classification in later functions.
    // Languages with local-variable queries conservatively invalidate that scope.
    let before = grammar.locals == nil ? enclosingRange(edit.range) : localScopeRange(edit.range)
    var inputEdit = try text.replace(edit)
    if let tree { ts_tree_edit(tree, &inputEdit) }
    needsParse = true
    var retained: [Child] = []
    for var child in children {
      if edit.range.location >= child.range.location, NSMaxRange(edit.range) <= NSMaxRange(child.range) {
        _ = try child.document.apply(
          .init(
            range: NSRange(
              location: edit.range.location - child.range.location,
              length: edit.range.length), text: edit.text))
        child.range.length += edit.text.utf16.count - edit.range.length
        retained.append(child)
      } else if NSMaxRange(edit.range) <= child.range.location || edit.range.location >= NSMaxRange(child.range) {
        child.range = child.range.translated(by: edit)
        retained.append(child)
      }
    }
    children = retained
    return before.translated(by: edit)
  }

  private func localScopeRange(_ range: NSRange) -> NSRange {
    guard let tree, let locals = grammar.locals else { return enclosingRange(range) }
    let matches = try? locals.matches(tree: tree, source: text.units, range: range)
    let scopes = (matches ?? []).flatMap(\.captures).filter {
      $0.name == "local.scope" && $0.range.location <= range.location && NSMaxRange($0.range) >= NSMaxRange(range)
    }
    return scopes.min(by: { $0.range.length < $1.range.length })?.range ?? NSRange(location: 0, length: text.count)
  }

  func parse() throws -> NSRange? {
    struct InputBuffer { let bytes: UnsafeRawBufferPointer }
    let next: OpaquePointer? = text.units.withUnsafeBytes { bytes in
      var buffer = InputBuffer(bytes: bytes)
      return withUnsafeMutablePointer(to: &buffer) { context in
        let input = TSInput(
          payload: UnsafeMutableRawPointer(context),
          read: { payload, index, _, length in
            let bytes = payload!.assumingMemoryBound(to: InputBuffer.self).pointee.bytes
            let remaining = max(0, bytes.count - Int(index))
            length!.pointee = UInt32(min(remaining, 8192))
            guard remaining > 0 else { return nil }
            return bytes.baseAddress!.advanced(by: Int(index)).assumingMemoryBound(to: CChar.self)
          }, encoding: TSInputEncodingUTF16LE, decode: nil)
        return ts_parser_parse_with_options(
          parser, tree, input,
          TSParseOptions(payload: nil, progress_callback: { _ in Task.isCancelled }))
      }
    }
    guard let next else {
      ts_parser_reset(parser)
      throw TreeSitterError.parse
    }
    parseCount += 1
    localReferencesCache = nil
    var changed: NSRange?
    if let old = tree {
      var count: UInt32 = 0
      if let ranges = ts_tree_get_changed_ranges(old, next, &count) {
        defer { free(ranges) }
        for index in 0..<Int(count) {
          let item = ranges[index]
          let range = NSRange(location: Int(item.start_byte) / 2, length: Int(item.end_byte - item.start_byte) / 2)
          changed = changed.map { NSUnionRange($0, range) } ?? range
        }
      }
      ts_tree_delete(old)
    } else {
      changed = NSRange(location: 0, length: text.count)
    }
    tree = next
    needsParse = false
    return changed
  }

  /// Include the containing top-level construct because queries can depend on
  /// ancestors and siblings. A text edit matters even when tree shape is unchanged.
  func enclosingRange(_ range: NSRange) -> NSRange {
    guard let tree, text.count > 0 else { return NSRange(location: 0, length: text.count) }
    let root = ts_tree_root_node(tree)
    let start = min(range.location, max(0, text.count - 1))
    let end = min(text.count, max(start + 1, NSMaxRange(range)))
    var node = ts_node_descendant_for_byte_range(root, UInt32(start * 2), UInt32(end * 2))
    if ts_node_is_null(node) { return NSRange(location: 0, length: text.count) }
    while true {
      let parent = ts_node_parent(node)
      if ts_node_is_null(parent) || ts_node_eq(parent, root) { break }
      node = parent
    }
    return NSRange(
      location: Int(ts_node_start_byte(node)) / 2,
      length: Int(ts_node_end_byte(node) - ts_node_start_byte(node)) / 2)
  }

  func spans(in range: NSRange, depth: Int = 0) throws -> [SyntaxSpan] {
    guard let tree else { return [] }
    let locals = try localReferences(tree: tree)
    let matches = try grammar.highlights.matches(
      tree: tree, source: text.units, range: range,
      isLocal: { locals.contains(Int(ts_node_start_byte($0))) })
    var spans: [SyntaxSpan] = matches.flatMap { match in
      match.captures.compactMap { capture in
        guard !capture.name.hasPrefix("_"), capture.name != "spell", capture.name != "nospell",
          capture.range.length > 0
        else { return nil }
        return SyntaxSpan(
          range: capture.range, capture: capture.name, language: grammar.name,
          priority: depth * 1_000_000 + (Int(match.properties["priority"] ?? "100") ?? 100) * 1000,
          order: match.pattern)
      }
    }
    guard depth < 6, let query = grammar.injections else { return spans }
    let injections = try query.matches(tree: tree, source: text.units, range: range)
    var used: [Child] = []
    for match in injections {
      var language = match.properties["injection.language"]
      if let name = match.captures.first(where: { $0.name == "injection.language" }) {
        language = String(decoding: text.units[name.range.location..<NSMaxRange(name.range)], as: UTF16.self)
      }
      guard let name = language,
        let resolved = name == "markdown_inline" ? name : SyntaxLanguage.resolve(name)?.rawValue
      else { continue }
      for capture in match.captures where capture.name == "injection.content" {
        // Child documents use local ranges. Only the injected source is copied,
        // and unchanged children are reused on subsequent highlight requests.
        let region = capture.range
        guard region.length > 0, !(region.location == 0 && region.length == text.count && resolved == grammar.name)
        else { continue }
        let child: TreeSitterDocument
        if let existing = children.first(where: { $0.range == region && $0.document.grammar.name == resolved }) {
          child = existing.document
        } else {
          let source = String(decoding: text.units[region.location..<NSMaxRange(region)], as: UTF16.self)
          child = try TreeSitterDocument(source: source, language: resolved)
        }
        if child.needsParse { _ = try child.parse() }
        used.append(Child(range: region, document: child))
        let clipped = NSIntersectionRange(region, range)
        let childRange = NSRange(location: max(0, clipped.location - region.location), length: clipped.length)
        spans += try child.spans(in: childRange, depth: depth + 1).map {
          SyntaxSpan(
            range: NSRange(location: region.location + $0.range.location, length: $0.range.length),
            capture: $0.capture, language: $0.language, priority: $0.priority, order: $0.order)
        }
      }
    }
    children = children.filter { NSIntersectionRange($0.range, range).length == 0 } + used
    return spans
  }

  private func localReferences(tree: OpaquePointer) throws -> Set<Int> {
    if let localReferencesCache { return localReferencesCache }
    guard let query = grammar.locals else { return [] }
    let matches = try query.matches(tree: tree, source: text.units)
    func key(_ node: TSNode) -> String {
      "\(ts_node_start_byte(node)):\(ts_node_end_byte(node)):\(String(cString: ts_node_type(node)))"
    }
    let root = ts_tree_root_node(tree)
    let rootKey = key(root)
    var scopes: [String: Bool] = [rootKey: true]
    var definitions: [TreeSitterQuery.Capture] = []
    var references: [TreeSitterQuery.Capture] = []
    for match in matches {
      for capture in match.captures {
        switch capture.name {
        case "local.scope": scopes[key(capture.node)] = match.properties["local.scope-inherits"] != "false"
        case "local.definition": definitions.append(capture)
        case "local.reference": references.append(capture)
        default: break
        }
      }
    }
    func enclosingScopes(_ node: TSNode) -> [String] {
      var node = node
      var result: [String] = []
      while !ts_node_is_null(node) {
        let id = key(node)
        if let inherits = scopes[id] {
          result.append(id)
          if !inherits { break }
        }
        node = ts_node_parent(node)
      }
      return result
    }
    func name(_ capture: TreeSitterQuery.Capture) -> String {
      String(decoding: text.units[capture.range.location..<NSMaxRange(capture.range)], as: UTF16.self)
    }
    var namesByScope: [String: Set<String>] = [:]
    for definition in definitions {
      namesByScope[enclosingScopes(definition.node).first ?? rootKey, default: []].insert(name(definition))
    }
    var result = Set(definitions.map { $0.range.location * 2 })
    for reference in references {
      let value = name(reference)
      if enclosingScopes(reference.node).contains(where: { namesByScope[$0]?.contains(value) == true }) {
        result.insert(reference.range.location * 2)
      }
    }
    localReferencesCache = result
    return result
  }
}
