import CodevisorCore
import SwiftUI

enum FeatureFlag: String, CaseIterable, Identifiable {
  case bots
  case developerMode
  case gmailPlugin

  var id: String { rawValue }

  var preferenceKey: String { "featureFlags.\(rawValue)" }

  var title: String {
    switch self {
    case .bots: "Bots"
    case .developerMode: "Developer Mode"
    case .gmailPlugin: "Gmail Plugin"
    }
  }

  var detail: String {
    switch self {
    case .bots: "Adds a Chat mode to the sidebar for long-lived bots that work across several projects."
    case .developerMode: "Adds a Developer section to the command palette with tools such as the debug overlay."
    case .gmailPlugin:
      "Shows Gmail in Browse Plugins on all your devices. In testing: only @851.sh Google accounts can sign in."
    }
  }

  @MainActor
  var isEnabled: Bool {
    get { ClientPreferences.shared.value(forKey: preferenceKey, default: false) }
    nonmutating set { ClientPreferences.shared.set(newValue, forKey: preferenceKey) }
  }
}
