import CodevisorCore
import CodevisorUI

enum SyncedPreferences {
  static let keys: Set<String> = SidebarPreferenceKey.synced.union([
    ModelConfigMenu.favoriteModelsKey,
    NewChatView.favoriteProjectsKey,
    SandboxesFeature.preferenceKey,
  ])
}
