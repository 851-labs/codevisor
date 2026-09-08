import Foundation

/// Local, bounded address-bar history, isolated by workspace machine/profile.
@MainActor
public final class BrowserHistory {
  public struct Visit: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
  }
  public static let shared = BrowserHistory()
  private let defaults: UserDefaults?
  private var profiles: [String: [Visit]] = [:]

  public init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

  public func visits(profile: String) -> [Visit] {
    if let cached = profiles[profile] { return cached }
    let saved =
      defaults?.data(forKey: "browserHistory.\(profile)")
      .flatMap { try? JSONDecoder().decode([Visit].self, from: $0) } ?? []
    profiles[profile] = saved
    return saved
  }

  public func record(url: String, title: String, profile: String) {
    guard let canonical = BrowserLocation.sharedURL(url) else { return }
    let visit = Visit(url: canonical.absoluteString, title: title)
    var recent = visits(profile: profile)
    if recent.first == visit { return }
    recent.removeAll { $0.url == visit.url }
    recent.insert(visit, at: 0)
    recent = Array(recent.prefix(200))
    profiles[profile] = recent
    if let data = try? JSONEncoder().encode(recent) { defaults?.set(data, forKey: "browserHistory.\(profile)") }
  }
}
