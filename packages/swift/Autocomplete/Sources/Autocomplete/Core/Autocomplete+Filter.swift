import Foundation

public extension Autocomplete {
  struct Filter: Sendable {
    enum Strategy { case contains, startsWith, subsequence, custom }
    let id = UUID()
    var strategy: Strategy = .custom
    private let predicate: @Sendable (_ candidate: String, _ query: String) -> Bool

    public init(_ predicate: @escaping @Sendable (_ candidate: String, _ query: String) -> Bool) {
      self.predicate = predicate
    }

    public func matches(_ candidate: String, query: String) -> Bool {
      predicate(candidate, query)
    }

    public static let contains = preset(.contains) { candidate, query in
      query.isEmpty || candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    public static let startsWith = preset(.startsWith) { candidate, query in
      query.isEmpty || candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
    }

    public static let subsequence = preset(.subsequence) { candidate, query in
      var remaining = normalized(query)[...]
      return matchesSubsequence(normalized(candidate), remaining: &remaining)
    }
    private static func matchesSubsequence(_ candidate: String, remaining: inout Substring) -> Bool {
      for character in candidate {
        guard let next = remaining.first else { return true }
        if character == next {
          remaining = remaining.dropFirst()
        }
      }
      return remaining.isEmpty
    }

    private static func preset(
      _ strategy: Strategy, _ predicate: @escaping @Sendable (String, String) -> Bool
    ) -> Filter {
      var filter = Filter(predicate)
      filter.strategy = strategy
      return filter
    }

    static func normalized(_ text: String, locale: Locale = .current) -> String {
      text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    func matchesPrepared(_ candidate: String, original: String, query: String, originalQuery: String) -> Bool {
      switch strategy {
      case .contains: return candidate.contains(query)
      case .startsWith: return candidate.hasPrefix(query)
      case .subsequence:
        var remaining = query[...]
        return Self.matchesSubsequence(candidate, remaining: &remaining)
      case .custom: return matches(original, query: originalQuery)
      }
    }
  }
}
