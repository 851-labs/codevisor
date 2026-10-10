import CTreeSitter
import Foundation

/// Stateless host predicate interpretation over one copied match; no C handle ownership.
enum TreeSitterPredicateEvaluator {
  private typealias Argument = TreeSitterPredicateCompiler.Argument
  private typealias Predicate = TreeSitterPredicateCompiler.Predicate

  static func evaluate(
    captures: [TSQueryCapture], predicates: [TreeSitterPredicateCompiler.Predicate], names: [String],
    pattern: Int, source: [UInt16], isLocal: (TSNode) -> Bool
  ) -> TreeSitterQuery.Match? {
    func values(_ argument: Argument) -> [String] {
      switch argument {
      case .string(let value): [value]
      case .capture(let id): captures.filter { $0.index == id }.map { text($0.node, source: source) }
      }
    }
    var properties: [String: String] = [:]
    guard
      predicates.allSatisfy({
        accepts($0, captures: captures, values: values, isLocal: isLocal, properties: &properties)
      })
    else { return nil }
    var selected = captures.map { TreeSitterQuery.Capture(name: names[Int($0.index)], node: $0.node) }
    for predicate in predicates where predicate.name == "offset!" {
      applyOffset(predicate, captures: captures, source: source, values: values, selected: &selected)
    }
    return TreeSitterQuery.Match(captures: selected, properties: properties, pattern: pattern)
  }

  private static func text(_ node: TSNode, source: [UInt16]) -> String {
    let start = Int(ts_node_start_byte(node)) / 2
    let end = min(source.count, Int(ts_node_end_byte(node)) / 2)
    return String(decoding: source[min(start, end)..<end], as: UTF16.self)
  }

  private static func accepts(
    _ predicate: Predicate, captures: [TSQueryCapture], values: (Argument) -> [String],
    isLocal: (TSNode) -> Bool, properties: inout [String: String]
  ) -> Bool {
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
    return comparison(predicate, left: values(first), right: args.dropFirst().flatMap(values))
  }

  private static func comparison(_ predicate: Predicate, left: [String], right: [String]) -> Bool {
    let negate = predicate.name.contains("not-")
    let outcomes = left.map { value -> Bool in
      let matched: Bool
      if let regex = predicate.regex {
        matched = regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
      } else {
        matched = right.contains(value)
      }
      return negate ? !matched : matched
    }
    return !outcomes.isEmpty
      && (predicate.name.hasPrefix("any-") && !predicate.name.contains("of?")
        ? outcomes.contains(true) : outcomes.allSatisfy { $0 })
  }

  private static func applyOffset(
    _ predicate: Predicate, captures: [TSQueryCapture], source: [UInt16], values: (Argument) -> [String],
    selected: inout [TreeSitterQuery.Capture]
  ) {
    guard predicate.arguments.count == 5, case .capture(let id) = predicate.arguments[0] else { return }
    let offsets = predicate.arguments.dropFirst().compactMap { values($0).first.flatMap(Int.init) }
    guard offsets.count == 4 else { return }
    for index in selected.indices where captures[index].index == id {
      let old = selected[index].range
      let start = shifted(old.location, rows: offsets[0], columns: offsets[1], source: source)
      let end = shifted(NSMaxRange(old), rows: offsets[2], columns: offsets[3], source: source)
      selected[index].adjustedRange = NSRange(location: start, length: max(0, end - start))
    }
  }

  private static func shifted(_ offset: Int, rows: Int, columns: Int, source: [UInt16]) -> Int {
    var position = offset
    if rows > 0 {
      for _ in 0..<rows { advanceLine(&position, source: source) }
    } else if rows < 0 {
      for _ in rows..<0 { retreatLine(&position, source: source) }
    }
    return min(source.count, max(0, position + columns))
  }

  private static func advanceLine(_ position: inout Int, source: [UInt16]) {
    while position < source.count, source[position] != 10 { position += 1 }
    position = min(source.count, position + 1)
  }

  private static func retreatLine(_ position: inout Int, source: [UInt16]) {
    position = max(0, position - 1)
    while position > 0, source[position - 1] != 10 { position -= 1 }
  }
}
