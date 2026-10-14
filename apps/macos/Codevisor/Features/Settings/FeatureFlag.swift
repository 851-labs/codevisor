import CodevisorCore
import Foundation

/// Unfinished or opt-in client features, toggled in Settings ▸ Developer.
/// Per device; every flag is off by default, so clients keep the shipped
/// experience until someone opts in.
enum FeatureFlag: String, CaseIterable, Identifiable {
  /// The workspace tab strip above the content, a sidebar of one row per
  /// workspace with grouping, pinning, an archive, and PR badges, and a
  /// per-workspace navigator on the trailing edge led by a file tree.
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
        + "machine, with pinning, an archive, and PR badges. A navigator on the right of each workspace (⌥⌘0) "
        + "with a file tree that opens files in preview tabs."
    }
  }

  private var preferenceKey: String { "featureFlags.\(rawValue)" }

  /// Read from views and commands alike; preferences are observable, so a
  /// toggle takes effect at once.
  var isEnabled: Bool {
    get { ClientPreferences.shared.value(forKey: preferenceKey, default: false) }
    nonmutating set { ClientPreferences.shared.set(newValue, forKey: preferenceKey) }
  }
}
