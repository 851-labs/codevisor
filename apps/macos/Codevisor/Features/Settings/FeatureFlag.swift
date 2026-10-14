import CodevisorCore
import Foundation

enum FeatureFlag: String, CaseIterable, Identifiable {
  case sidebarRefresh

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sidebarRefresh: "Sidebar refresh"
    }
  }

  var detail: String {
    switch self {
    case .sidebarRefresh:
      "Workspace tabs in a strip above the content, and one sidebar row per workspace, grouped by project or "
        + "machine, with pinning, an archive, and PR badges."
    }
  }

  private var preferenceKey: String { "featureFlags.\(rawValue)" }

  var isEnabled: Bool {
    get { ClientPreferences.shared.value(forKey: preferenceKey, default: false) }
    nonmutating set { ClientPreferences.shared.set(newValue, forKey: preferenceKey) }
  }
}
