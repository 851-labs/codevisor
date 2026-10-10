import Foundation

/// Compiles and scores the ordered scope terms of one TextMate selector.
struct TextMateScopeSelector: Sendable {
  let required: [String]
  let excluded: [String]

  init?(_ source: String) {
    var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("L:") || value.hasPrefix("R:") {
      value.removeFirst(2)
      value = value.trimmingCharacters(in: .whitespaces)
    }
    guard !value.isEmpty else { return nil }

    let pieces = value.components(separatedBy: " - ")
    required = pieces[0].split(whereSeparator: \.isWhitespace).map(String.init)
    excluded = pieces.dropFirst().flatMap {
      $0.split(whereSeparator: \.isWhitespace).map(String.init)
    }
    guard !required.isEmpty else { return nil }
  }

  func score(in stack: [String]) -> Int? {
    guard excluded.allSatisfy({ term in !stack.contains(where: { matches(term, $0) }) })
    else { return nil }

    var stackIndex = stack.count - 1
    var score = 0
    for term in required.reversed() {
      guard let matchIndex = matchingIndex(for: term, in: stack, before: &stackIndex) else { return nil }
      addSpecificity(for: term, at: matchIndex, in: stack, to: &score)
      stackIndex = matchIndex - 1
    }
    score += required.count * 1_000
    return score
  }

  private func matchingIndex(for term: String, in stack: [String], before stackIndex: inout Int) -> Int? {
    var matchIndex: Int?
    while stackIndex >= 0 {
      if matches(term, stack[stackIndex]) {
        matchIndex = stackIndex
        break
      }
      stackIndex -= 1
    }
    return matchIndex
  }

  private func addSpecificity(for term: String, at matchIndex: Int, in stack: [String], to score: inout Int) {
    let componentCount = term.split(separator: ".").count
    score += componentCount * 100 + term.count
    // A selector naming the leaf scope is more specific than one
    // that only matches a parent scope.
    if matchIndex == stack.count - 1 { score += 10_000 }
  }

  private func matches(_ selector: String, _ scope: String) -> Bool {
    selector == "*" || scope == selector || scope.hasPrefix(selector + ".")
  }
}
