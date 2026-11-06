import CodevisorCore
import Foundation

public enum RetiredChildDisclosure {
  static let expandedPreferenceKey = "sidebar.expandedChildren"
  static let collapsedIDPrefix = "workspace:"

  @MainActor
  public static func clear(in preferences: ClientPreferences = .shared) {
    clearExpanded(in: preferences)
    clearCollapsed(in: preferences)
  }

  @MainActor
  private static func clearExpanded(in preferences: ClientPreferences) {
    guard preferences.valueIfPresent(forKey: expandedPreferenceKey, as: [String].self) != nil else { return }

    preferences.removeValue(forKey: expandedPreferenceKey)
  }

  @MainActor
  private static func clearCollapsed(in preferences: ClientPreferences) {
    let key = SidebarGrouping.collapsedPreferenceKey
    let collapsed = preferences.value(forKey: key, default: [String]())
    let kept = collapsed.filter { !$0.hasPrefix(collapsedIDPrefix) }
    guard kept != collapsed else { return }

    preferences.set(kept, forKey: key)
  }
}
