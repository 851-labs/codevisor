import CTreeSitter
import Foundation

/// Swift ownership and predicate evaluation for the C query API. C returns
/// structural matches; text predicates and properties are the host's job.
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
  private enum Argument {
    case capture(UInt32)
    case string(String)
  }
  private struct Predicate {
    let name: String
    let arguments: [Argument]
    let regex: NSRegularExpression?
  }

  let pointer: OpaquePointer
  private let names: [String]
  private let predicates: [[Predicate]]
  var usesLocals: Bool { predicates.joined().contains { $0.name == "is?" || $0.name == "is-not?" } }

  init(language: OpaquePointer, source: String, name: String) throws {
    var offset: UInt32 = 0
    var error = TSQueryErrorNone
    guard let query = source.withCString({ ts_query_new(language, $0, UInt32(source.utf8.count), &offset, &error) })
    else { throw TreeSitterError.query(name, offset, error) }
    pointer = query
    do {
      names = (0..<ts_query_capture_count(query)).map { index in
        var count: UInt32 = 0
        return String(
          decoding: UnsafeBufferPointer(
            start: UnsafeRawPointer(ts_query_capture_name_for_id(query, index, &count)!).assumingMemoryBound(
              to: UInt8.self),
            count: Int(count)), as: UTF8.self)
      }
      predicates = try (0..<ts_query_pattern_count(query)).map { pattern in
        var count: UInt32 = 0
        let steps = ts_query_predicates_for_pattern(query, pattern, &count)
        var arguments: [Argument] = []
        var result: [Predicate] = []
        for index in 0..<Int(count) {
          let step = steps![index]
          switch step.type {
          case TSQueryPredicateStepTypeCapture: arguments.append(.capture(step.value_id))
          case TSQueryPredicateStepTypeString:
            var length: UInt32 = 0
            let value = ts_query_string_value_for_id(query, step.value_id, &length)!
            arguments.append(
              .string(
                String(
                  decoding: UnsafeBufferPointer(
                    start: UnsafeRawPointer(value).assumingMemoryBound(to: UInt8.self), count: Int(length)),
                  as: UTF8.self)))
          default:
            guard case .string(let operation) = arguments.first else { continue }
            let supported = [
              "eq?", "not-eq?", "any-eq?", "any-not-eq?", "match?", "not-match?",
              "any-match?", "any-not-match?", "any-of?", "not-any-of?", "is?", "is-not?", "set!", "offset!",
            ]
            guard supported.contains(operation) else { throw TreeSitterError.predicate(operation) }
            let values = Array(arguments.dropFirst())
            var regex: NSRegularExpression?
            if operation.contains("match?"), case .string(let expression) = values.last {
              regex = try NSRegularExpression(pattern: expression)
            }
            result.append(Predicate(name: operation, arguments: values, regex: regex))
            arguments.removeAll(keepingCapacity: true)
          }
        }
        return result
      }
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
      let captures = Array(UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count)))
      func text(_ node: TSNode) -> String {
        let start = Int(ts_node_start_byte(node)) / 2
        let end = min(source.count, Int(ts_node_end_byte(node)) / 2)
        return String(decoding: source[min(start, end)..<end], as: UTF16.self)
      }
      func values(_ argument: Argument) -> [String] {
        switch argument {
        case .string(let value): [value]
        case .capture(let id): captures.filter { $0.index == id }.map { text($0.node) }
        }
      }
      var properties: [String: String] = [:]
      let accepted = predicates[Int(match.pattern_index)].allSatisfy { predicate in
        let args = predicate.arguments
        guard let first = args.first else { return false }
        if predicate.name == "offset!" { return true }
        if predicate.name == "set!" {
          guard case .string(let key) = first else { return false }
          properties[key] = args.count > 1 ? values(args[1]).first ?? "" : "true"
          return true
        }
        if predicate.name == "is?" || predicate.name == "is-not?" {
          guard case .string("local") = first else { return false }
          let local = captures.contains { isLocal($0.node) }
          return predicate.name == "is?" ? local : !local
        }
        guard args.count > 1 else { return false }
        let left = values(first)
        let right = args.dropFirst().flatMap(values)
        let negate = predicate.name.contains("not-")
        let outcomes = left.map { value -> Bool in
          let matched: Bool
          if let regex = predicate.regex {
            matched =
              regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
          } else {
            matched = right.contains(value)
          }
          return negate ? !matched : matched
        }
        return !outcomes.isEmpty
          && (predicate.name.hasPrefix("any-") && !predicate.name.contains("of?")
            ? outcomes.contains(true) : outcomes.allSatisfy { $0 })
      }
      if accepted {
        var selected = captures.map { Capture(name: names[Int($0.index)], node: $0.node) }
        for predicate in predicates[Int(match.pattern_index)] where predicate.name == "offset!" {
          guard predicate.arguments.count == 5, case .capture(let id) = predicate.arguments[0] else { continue }
          let offsets = predicate.arguments.dropFirst().compactMap { values($0).first.flatMap(Int.init) }
          guard offsets.count == 4 else { continue }
          func shifted(_ offset: Int, rows: Int, columns: Int) -> Int {
            var position = offset
            if rows > 0 {
              for _ in 0..<rows {
                while position < source.count, source[position] != 10 { position += 1 }
                position = min(source.count, position + 1)
              }
            } else if rows < 0 {
              for _ in rows..<0 {
                position = max(0, position - 1)
                while position > 0, source[position - 1] != 10 { position -= 1 }
              }
            }
            return min(source.count, max(0, position + columns))
          }
          for index in selected.indices where captures[index].index == id {
            let old = selected[index].range
            let start = shifted(old.location, rows: offsets[0], columns: offsets[1])
            let end = shifted(NSMaxRange(old), rows: offsets[2], columns: offsets[3])
            selected[index].adjustedRange = NSRange(location: start, length: max(0, end - start))
          }
        }
        result.append(
          Match(
            captures: selected,
            properties: properties, pattern: Int(match.pattern_index)))
      }
    }
    guard !ts_query_cursor_did_exceed_match_limit(cursor) else { throw TreeSitterError.parse }
    return result
  }
}
