import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

@MainActor
struct RetiredChildDisclosureTests {
  @Test("Clearing drops stored per-parent collapse and expand choices and keeps section and group collapsing")
  func clearsOnlyParentDisclosure() {
    let preferences = ClientPreferences()
    let section = SidebarWorkspaceGroup.customSectionID(UUID())
    preferences.set(
      ["machine:studio", "workspace:\(UUID().uuidString)", section], forKey: SidebarGrouping.collapsedPreferenceKey)
    preferences.set(["workspace:\(UUID().uuidString)"], forKey: RetiredChildDisclosure.expandedPreferenceKey)

    RetiredChildDisclosure.clear(in: preferences)

    #expect(
      preferences.value(forKey: SidebarGrouping.collapsedPreferenceKey, default: [String]()) == [
        "machine:studio", section,
      ])
    #expect(preferences.valueIfPresent(forKey: RetiredChildDisclosure.expandedPreferenceKey, as: [String].self) == nil)
  }

  @Test("Clearing leaves preferences without retired choices untouched")
  func leavesCleanPreferencesAlone() {
    let preferences = ClientPreferences()
    preferences.set(["machine:studio"], forKey: SidebarGrouping.collapsedPreferenceKey)

    RetiredChildDisclosure.clear(in: preferences)

    #expect(
      preferences.value(forKey: SidebarGrouping.collapsedPreferenceKey, default: [String]()) == ["machine:studio"])
    #expect(preferences.valueIfPresent(forKey: RetiredChildDisclosure.expandedPreferenceKey, as: [String].self) == nil)
  }
}
