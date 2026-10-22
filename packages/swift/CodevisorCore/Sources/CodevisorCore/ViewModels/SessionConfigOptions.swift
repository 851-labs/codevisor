import Foundation
import Observation
import ACPKit

@MainActor
@Observable
final class SessionConfigOptions {
  private struct Change {
    let configId: String
    let value: String
    let revision: UInt64
    let previousValue: String?
  }

  var options: [SessionConfigOption]
  @ObservationIgnored private var revisions: [String: UInt64] = [:]
  @ObservationIgnored private var inFlightValues: [String: String] = [:]
  @ObservationIgnored var onFailure: ((any Error) -> Void)?

  private let transport: ServerSessionTransport

  init(options: [SessionConfigOption], transport: ServerSessionTransport) {
    self.options = options
    self.transport = transport
  }

  func adoptLive(_ live: [SessionConfigOption]) {
    options = preservingInFlightPicks(live)
  }

  @discardableResult
  func set(configId: String, value: String) async -> Bool {
    let change = begin(configId: configId, value: value)
    defer { finish(change) }

    do {
      let resolved = try await transport.setConfigOption(configId: configId, value: value)
      adopt(resolved, after: change)
      return true
    } catch {
      revert(change)
      onFailure?(error)
      return false
    }
  }

  private func preservingInFlightPicks(_ live: [SessionConfigOption]) -> [SessionConfigOption] {
    guard !inFlightValues.isEmpty else { return live }
    return live.map { option in
      guard let value = inFlightValues[option.id] else { return option }
      var updated = option
      updated.currentValue = value
      return updated
    }
  }

  private func begin(configId: String, value: String) -> Change {
    let revision = (revisions[configId] ?? 0) &+ 1
    revisions[configId] = revision
    inFlightValues[configId] = value
    let previousValue = showPick(value, for: configId)
    return Change(configId: configId, value: value, revision: revision, previousValue: previousValue)
  }

  private func showPick(_ value: String, for configId: String) -> String? {
    guard let index = options.firstIndex(where: { $0.id == configId }) else { return nil }
    let previousValue = options[index].currentValue
    options[index].currentValue = value
    return previousValue
  }

  private func adopt(_ resolved: [SessionConfigOption]?, after change: Change) {
    guard isCurrent(change), let resolved, !resolved.isEmpty else { return }
    options = resolved
  }

  private func revert(_ change: Change) {
    guard isCurrent(change), let previousValue = change.previousValue,
      let index = options.firstIndex(where: { $0.id == change.configId }),
      options[index].currentValue == change.value
    else { return }
    options[index].currentValue = previousValue
  }

  private func finish(_ change: Change) {
    guard isCurrent(change) else { return }
    inFlightValues[change.configId] = nil
  }

  private func isCurrent(_ change: Change) -> Bool {
    revisions[change.configId] == change.revision
  }
}
