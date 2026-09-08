import Foundation
import Observation

public struct BrowserSuggestion: Identifiable, Equatable, Sendable {
  public enum Kind: Sendable { case page, search }
  public let kind: Kind
  public let title: String
  public let value: String
  public var id: String { "\(kind):\(value)" }
}

@MainActor
@Observable
public final class BrowserSuggestions {
  public private(set) var items: [BrowserSuggestion] = []
  public private(set) var selectedID: String?
  public private(set) var query = ""
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var revision = 0
  private let profile: String
  private let history: BrowserHistory
  private let fetch: @MainActor (String) async throws -> [String]
  private let sleep: @MainActor () async throws -> Void

  public init(
    profile: String, history: BrowserHistory = .shared,
    fetch: @escaping @MainActor (String) async throws -> [String],
    sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(180)) }
  ) { self.profile = profile; self.history = history; self.fetch = fetch; self.sleep = sleep }

  public var selected: BrowserSuggestion? { items.first { $0.id == selectedID } }

  /// Returns the task so tests can acknowledge debounce, cancellation and reply
  /// order without sleeping or relying on the main executor's scheduling.
  @discardableResult
  public func update(_ input: String) -> Task<Void, Never>? {
    task?.cancel()
    revision += 1
    let token = revision
    query = input.trimmingCharacters(in: .whitespacesAndNewlines)
    selectedID = nil
    guard !query.isEmpty else { items = []; return nil }
    let typed = query
    let visits = history.visits(profile: profile).map { visit in
      BrowserHistory.Visit(url: Self.completionTarget(visit.url, for: typed), title: visit.title)
    }
    let matches = visits.filter {
      Self.completion($0.url, for: typed) != nil || $0.title.localizedCaseInsensitiveContains(typed)
        || $0.url.localizedCaseInsensitiveContains(typed)
    }
    let ranked =
      matches.filter { Self.completion($0.url, for: typed) != nil }
      + matches.filter { Self.completion($0.url, for: typed) == nil }
    var seenPages = Set<String>()
    items = ranked.filter { seenPages.insert($0.url).inserted }.prefix(3)
      .map { BrowserSuggestion(kind: .page, title: $0.title, value: $0.url) }
    if Self.allowsRemoteSuggestions(typed) {
      items.append(BrowserSuggestion(kind: .search, title: typed, value: typed))
    } else if items.isEmpty, let url = BrowserLocation.addressBarURL(typed) {
      items = [BrowserSuggestion(kind: .page, title: typed, value: url.absoluteString)]
    }
    if let first = items.first, first.kind == .page, Self.completion(first.value, for: typed) != nil {
      selectedID = first.id
    }
    guard Self.allowsRemoteSuggestions(typed) else { return nil }
    task = Task { [weak self, fetch, sleep] in
      do {
        try await sleep()
        try Task.checkCancellation()
        let values = try await fetch(typed)
        guard let self, !Task.isCancelled, self.revision == token else { return }
        var seen = Set(self.items.map(\.value))
        for value in values where !value.isEmpty && value.count <= 200 && seen.insert(value).inserted {
          self.items.append(BrowserSuggestion(kind: .search, title: value, value: value))
          if self.items.count >= 9 { break }
        }
      } catch { /* Local results and submitting the typed query always work. */  }
    }
    return task
  }

  public func dismiss() {
    task?.cancel(); task = nil; revision += 1
    items = []; selectedID = nil
  }

  public func moveSelection(_ offset: Int) {
    guard !items.isEmpty else { return }
    let index = items.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : items.count)
    selectedID = items[max(0, min(items.count - 1, index + offset))].id
  }

  public var inlineCompletion: String? {
    guard let first = items.first, first.kind == .page else { return nil }
    return Self.completion(first.value, for: query)
  }

  /// Completing a hostname must not silently append a previous search, deep
  /// link or query string. Paths are completed only after the user starts one.
  private static func completionTarget(_ address: String, for input: String) -> String {
    var typed = input
    if let scheme = typed.range(of: "://") { typed = String(typed[scheme.upperBound...]) }
    if let slash = typed.firstIndex(of: "/"), typed.index(after: slash) != typed.endIndex { return address }
    guard !typed.contains(where: \.isWhitespace), !typed.contains("?"), !typed.contains("#"),
      var url = URLComponents(string: address)
    else { return address }
    url.path = "/"; url.query = nil; url.fragment = nil
    guard let origin = url.url else { return address }
    if typed.hasSuffix("/") { typed.removeLast() }
    if typed.lowercased().hasPrefix("www.") { typed.removeFirst(4) }
    guard !typed.isEmpty, BrowserLocation.display(origin).lowercased().hasPrefix(typed.lowercased()) else {
      return address
    }
    return origin.absoluteString
  }

  static func completion(_ address: String, for input: String) -> String? {
    guard !input.isEmpty, !input.hasSuffix("://"), !input.contains(where: \.isWhitespace) else { return nil }
    var value = address
    if !input.contains("://") {
      if value.hasPrefix("https://") { value.removeFirst(8) }
      if value.hasPrefix("http://") { value.removeFirst(7) }
      if !input.lowercased().hasPrefix("www."), value.hasPrefix("www.") { value.removeFirst(4) }
    }
    if value.hasSuffix("/"), let path = URL(string: address)?.path, path.isEmpty || path == "/" { value.removeLast() }
    guard value.lowercased().hasPrefix(input.lowercased()), value.count > input.count else { return nil }
    return input + value.dropFirst(input.count)
  }

  public static func allowsRemoteSuggestions(_ input: String) -> Bool {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 200,
      text.rangeOfCharacter(from: CharacterSet(charactersIn: ":/\\@?#=")) == nil,
      !text.lowercased().contains("localhost")
    else { return false }
    // Hostnames, IPs and paths are navigations, never search-provider input.
    return text.contains(where: \.isWhitespace) || !text.contains(".")
  }
}
