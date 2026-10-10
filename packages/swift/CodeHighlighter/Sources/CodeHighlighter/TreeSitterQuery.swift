import CTreeSitter
import Foundation

/// Owns the C query and per-call cursor; delegates host predicate semantics.
final class TreeSitterQuery {
  struct Capture {
    let name: String
    let node: TSNode
    var adjustedRange: NSRange?
    var range: NSRange {
      if let adjustedRange { return adjustedRange }
      let start = Int(ts_node_start_byte(node)) / 2
      return NSRange(location: start, length: Int(ts_node_end_byte(node)) / 2 - start)
    }
  }
  struct Match {
    let captures: [Capture]
    let properties: [String: String]
    let pattern: Int
  }
  let pointer: OpaquePointer
  private let names: [String]
  private let predicates: [[TreeSitterPredicateCompiler.Predicate]]
  var usesLocals: Bool { predicates.joined().contains { $0.name == "is?" || $0.name == "is-not?" } }

  init(language: OpaquePointer, source: String, name: String) throws {
    var offset: UInt32 = 0
    var error = TSQueryErrorNone
    guard let query = source.withCString({ ts_query_new(language, $0, UInt32(source.utf8.count), &offset, &error) })
    else { throw TreeSitterError.query(name, offset, error) }
    pointer = query
    do {
      names = TreeSitterPredicateCompiler.captureNames(query)
      predicates = try TreeSitterPredicateCompiler.compile(query)
    } catch {
      ts_query_delete(query)
      throw error
    }
  }

  deinit { ts_query_delete(pointer) }

  func matches(
    tree: OpaquePointer, source: [UInt16], range: NSRange? = nil,
    isLocal: (TSNode) -> Bool = { _ in false }
  ) throws -> [Match] {
    guard let cursor = ts_query_cursor_new() else { throw TreeSitterError.parse }
    defer { ts_query_cursor_delete(cursor) }
    ts_query_cursor_set_match_limit(cursor, 65_536)
    if let range { ts_query_cursor_set_byte_range(cursor, UInt32(range.location * 2), UInt32(NSMaxRange(range) * 2)) }
    ts_query_cursor_exec(cursor, pointer, ts_tree_root_node(tree))
    var match = TSQueryMatch()
    var result: [Match] = []
    while ts_query_cursor_next_match(cursor, &match) {
      try Task.checkCancellation()
      if let selected = evaluatedMatch(match, source: source, isLocal: isLocal) { result.append(selected) }
    }
    guard !ts_query_cursor_did_exceed_match_limit(cursor) else { throw TreeSitterError.parse }
    return result
  }

  private func evaluatedMatch(_ match: TSQueryMatch, source: [UInt16], isLocal: (TSNode) -> Bool) -> Match? {
    let captures = Array(UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count)))
    return TreeSitterPredicateEvaluator.evaluate(
      captures: captures, predicates: predicates[Int(match.pattern_index)], names: names,
      pattern: Int(match.pattern_index), source: source, isLocal: isLocal)
  }
}
