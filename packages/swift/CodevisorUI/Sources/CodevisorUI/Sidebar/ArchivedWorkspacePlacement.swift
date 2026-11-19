import CodevisorCore
import SwiftUI

public struct ArchivedWorkspacePlacement: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedIDs: [String]

  public init() {}

  public func body(content: Content) -> some View {
    content.onChange(of: archivedIDs, initial: true) { _, archived in
      forgetPlacement(of: archived)
    }
  }

  private var archivedIDs: Set<UUID> {
    Set(environment.navigationStore.workspaceEntries.archived.map(\.id))
  }

  private func forgetPlacement(of archived: Set<UUID>) {
    let kept = pinnedIDs.filter { pinned in !Self.isArchived(pinned, in: archived) }
    if kept != pinnedIDs { pinnedIDs = kept }
    for id in archived { environment.workspaceSections.forget(id) }
  }

  private static func isArchived(_ pinned: String, in archived: Set<UUID>) -> Bool {
    guard let id = UUID(uuidString: pinned) else { return false }
    return archived.contains(id)
  }
}

extension View {
  public func forgetsPlacementOfArchivedWorkspaces() -> some View {
    modifier(ArchivedWorkspacePlacement())
  }
}
