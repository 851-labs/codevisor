import CodevisorCore
import SwiftUI

enum FeatureFlag: String, CaseIterable, Identifiable {
  case bots

  var id: String { rawValue }

  var preferenceKey: String { "featureFlags.\(rawValue)" }

  var title: String {
    switch self {
    case .bots: "Bots"
    }
  }

  var detail: String {
    switch self {
    case .bots: "Adds a Bots section to the sidebar for long-lived agents that work across several projects."
    }
  }

  @MainActor
  var isEnabled: Bool {
    get { ClientPreferences.shared.value(forKey: preferenceKey, default: false) }
    nonmutating set { ClientPreferences.shared.set(newValue, forKey: preferenceKey) }
  }
}
