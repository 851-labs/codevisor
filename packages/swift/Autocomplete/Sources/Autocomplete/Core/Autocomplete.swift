import Foundation
import Observation

public enum Autocomplete {
  enum KeyCommand: Sendable, Hashable {
    case moveUp, moveDown, moveToFirst, moveToLast, accept, dismiss
  }

  enum FavoriteAction: Sendable, Hashable {
    case add
    case remove

    init(isFavorite: Bool) {
      self = isFavorite ? .remove : .add
    }

    var symbolName: String {
      switch self {
      case .add: "star"
      case .remove: "star.slash"
      }
    }

    var label: String {
      switch self {
      case .add: Strings.text("Add to Favorites")
      case .remove: Strings.text("Remove from Favorites")
      }
    }
  }

  public struct Filter: Sendable {
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

  @MainActor
  @Observable
  final class Highlight<ID: Hashable> {
    enum Source: Sendable, Hashable {
      case keyboard
      case pointer
    }

    var navigation: Navigation
    private(set) var highlighted: ID?
    private(set) var source: Source?
    private var searchQuery = ""

    private var autoHighlights: Bool { navigation.autoHighlight || !searchQuery.isEmpty }

    init(navigation: Navigation = .menu) {
      self.navigation = navigation
    }

    func hover(_ id: ID) {
      set(id, source: .pointer)
    }

    func endHover(_ id: ID) {
      guard highlighted == id, !autoHighlights else { return }
      set(nil, source: .pointer)
    }

    func focus(_ id: ID) { set(id, source: .keyboard) }

    func reset() {
      highlighted = nil
      source = nil
      searchQuery = ""
    }

    func reconcile(with targets: [ID], query: String? = nil) {
      if let query {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized != searchQuery {
          searchQuery = normalized
          set(autoHighlights ? targets.first : nil, source: .keyboard)
          return
        }
      }
      if let highlighted, !targets.contains(highlighted) {
        set(nil, source: .keyboard)
      }
      if highlighted == nil, autoHighlights {
        set(targets.first, source: .keyboard)
      }
    }

    func move(by offset: Int, in targets: [ID]) {
      guard !targets.isEmpty else {
        set(nil, source: .keyboard)
        return
      }
      guard let highlighted, let index = targets.firstIndex(of: highlighted) else {
        set(offset < 0 ? targets.last : targets.first, source: .keyboard)
        return
      }
      let nextIndex: Int
      if navigation.loop {
        nextIndex = ((index + offset) % targets.count + targets.count) % targets.count
      } else {
        nextIndex = min(max(index + offset, 0), targets.count - 1)
      }
      set(targets[nextIndex], source: .keyboard)
    }

    func moveToFirst(in targets: [ID]) {
      set(targets.first, source: .keyboard)
    }

    func moveToLast(in targets: [ID]) {
      set(targets.last, source: .keyboard)
    }

    @discardableResult
    func handle(
      _ command: KeyCommand,
      targets: [ID],
      accept: (ID) -> Void,
      dismiss: () -> Void
    ) -> Bool {
      switch command {
      case .moveUp:
        move(by: -1, in: targets)
      case .moveDown:
        move(by: 1, in: targets)
      case .moveToFirst:
        moveToFirst(in: targets)
      case .moveToLast:
        moveToLast(in: targets)
      case .accept:
        guard let highlighted, targets.contains(highlighted) else { return false }
        accept(highlighted)
      case .dismiss:
        dismiss()
      }
      return true
    }

    private func set(_ id: ID?, source: Source) {
      highlighted = id
      self.source = source
    }
  }

  public struct Navigation: Sendable, Hashable {
    public var loop: Bool
    public var autoHighlight: Bool

    public init(loop: Bool, autoHighlight: Bool) {
      self.loop = loop
      self.autoHighlight = autoHighlight
    }

    public static let menu = Navigation(loop: false, autoHighlight: false)

    public static let inline = Navigation(loop: true, autoHighlight: true)
  }

  enum Strings {
    static func text(_ key: String) -> String { Bundle.module.localizedString(forKey: key, value: nil, table: nil) }
    static func resultCount(_ count: Int) -> String { String(localized: "\(count) results", bundle: .module) }
    static func position(_ index: Int, count: Int) -> String {
      String(localized: "\(index) of \(count)", bundle: .module)
    }
  }
}
