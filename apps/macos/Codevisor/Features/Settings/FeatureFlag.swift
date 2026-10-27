import CodevisorCore
import SwiftUI

enum FeatureFlag: String, CaseIterable, Identifiable {
  case bots
  case sandboxes
  case developerMode

  var id: String { rawValue }

  var preferenceKey: String { "featureFlags.\(rawValue)" }

  var title: String {
    switch self {
    case .bots: "Bots"
    case .sandboxes: "Sandboxes"
    case .developerMode: "Developer Mode"
    }
  }

  var detail: String {
    switch self {
    case .bots: "Adds a Chat mode to the sidebar for long-lived bots that work across several projects."
    case .sandboxes: "Starts chats on throwaway machines from Tart, E2B, Modal and other vendors."
    case .developerMode: "Adds a Developer section to the command palette with tools such as the debug overlay."
    }
  }

  @MainActor
  var isEnabled: Bool {
    get { ClientPreferences.shared.value(forKey: preferenceKey, default: false) }
    nonmutating set { ClientPreferences.shared.set(newValue, forKey: preferenceKey) }
  }
}
