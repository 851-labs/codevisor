import Foundation

public enum FeatureFlag: String, CaseIterable, Identifiable, Sendable {
  case developerMode
  case gmailPlugin
  case slackPlugin

  public var id: String { rawValue }

  public var preferenceKey: String { "featureFlags.\(rawValue)" }

  public var title: String {
    switch self {
    case .developerMode: "Developer Mode"
    case .gmailPlugin: "Gmail Plugin"
    case .slackPlugin: "Slack Plugin"
    }
  }

  public var detail: String {
    switch self {
    case .developerMode: "Adds a Developer section to the command palette with tools such as the debug overlay."
    case .gmailPlugin:
      "Shows Gmail in Browse Plugins on all your devices. In testing: only @851.sh Google accounts can sign in."
    case .slackPlugin:
      "Shows Slack in Browse Plugins on all your devices. You connect it through a Slack app you create in your workspace."
    }
  }

  @MainActor
  public var isEnabled: Bool {
    ClientPreferences.shared.value(forKey: preferenceKey, default: false)
  }
}
