import CodevisorClient
import Foundation

@MainActor
public final class HarnessNoticeCenter {
  static let shownKey = "harnessNotices.shown.v1"

  private let preferences: ClientPreferences
  private let reporter: ErrorReporter

  public init(preferences: ClientPreferences = .shared, reporter: ErrorReporter = .shared) {
    self.preferences = preferences
    self.reporter = reporter
  }

  public func check(_ client: any CodevisorServerClienting) async {
    guard let harnesses = try? await client.listHarnesses() else { return }
    show(harnesses.compactMap(\.auth?.notice))
  }

  func show(_ notices: [ServerHarnessNotice]) {
    var shown = Set(preferences.value(forKey: Self.shownKey, default: [String]()))
    let unseen = notices.filter { shown.insert($0.id).inserted }
    guard !unseen.isEmpty else { return }

    for notice in unseen { reporter.notify(notice.message) }
    preferences.set(shown.sorted(), forKey: Self.shownKey)
  }
}
