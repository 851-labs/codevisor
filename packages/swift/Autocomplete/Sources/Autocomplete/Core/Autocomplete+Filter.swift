import Foundation

public extension Autocomplete {
  /// Decides whether a candidate string satisfies a query. Mirrors Base UI's
  /// `useFilter` presets.
  struct Filter: Sendable {
    private let predicate: @Sendable (_ candidate: String, _ query: String) -> Bool

    public init(_ predicate: @escaping @Sendable (_ candidate: String, _ query: String) -> Bool) {
      self.predicate = predicate
    }

    public func matches(_ candidate: String, query: String) -> Bool {
      predicate(candidate, query)
    }

    /// Case- and diacritic-insensitive containment — the behavior of Xcode's
    /// searchable menus.
    public static let contains = Filter { candidate, query in
      candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    public static let startsWith = Filter { candidate, query in
      candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
    }

    /// Every query character appears in the candidate in order, not
    /// necessarily adjacent — the behavior of command palettes.
    public static let subsequence = Filter { candidate, query in
      var remaining = query.lowercased()[...]
      for character in candidate.lowercased() {
        guard let next = remaining.first else { return true }
        if character == next {
          remaining = remaining.dropFirst()
        }
      }
      return remaining.isEmpty
    }
  }
}
