import CTreeSitter
import Foundation

/// Copies C predicate steps and compiles regexes once, during query initialization.
enum TreeSitterPredicateCompiler {
  enum Argument {
    case capture(UInt32)
    case string(String)
  }
  struct Predicate {
    let name: String
    let arguments: [Argument]
    let regex: NSRegularExpression?
  }

  static func captureNames(_ query: OpaquePointer) -> [String] {
    (0..<ts_query_capture_count(query)).map { index in
      var count: UInt32 = 0
      let pointer = ts_query_capture_name_for_id(query, index, &count)!
      return copiedString(pointer, count: count)
    }
  }

  static func compile(_ query: OpaquePointer) throws -> [[Predicate]] {
    try (0..<ts_query_pattern_count(query)).map { pattern in
      try compilePattern(query, pattern: pattern)
    }
  }

  private static func compilePattern(_ query: OpaquePointer, pattern: UInt32) throws -> [Predicate] {
    var count: UInt32 = 0
    let steps = ts_query_predicates_for_pattern(query, pattern, &count)
    var arguments: [Argument] = []
    var result: [Predicate] = []
    for index in 0..<Int(count) {
      let step = steps![index]
      switch step.type {
      case TSQueryPredicateStepTypeCapture: arguments.append(.capture(step.value_id))
      case TSQueryPredicateStepTypeString: arguments.append(.string(stringValue(query, id: step.value_id)))
      default:
        guard case .string(let operation) = arguments.first else { continue }
        result.append(try makePredicate(operation, arguments: arguments))
        arguments.removeAll(keepingCapacity: true)
      }
    }
    return result
  }

  private static func makePredicate(_ operation: String, arguments: [Argument]) throws -> Predicate {
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
    return Predicate(name: operation, arguments: values, regex: regex)
  }

  private static func stringValue(_ query: OpaquePointer, id: UInt32) -> String {
    var length: UInt32 = 0
    return copiedString(ts_query_string_value_for_id(query, id, &length)!, count: length)
  }

  private static func copiedString(_ pointer: UnsafePointer<CChar>, count: UInt32) -> String {
    String(
      decoding: UnsafeBufferPointer(
        start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(count)),
      as: UTF8.self)
  }
}
