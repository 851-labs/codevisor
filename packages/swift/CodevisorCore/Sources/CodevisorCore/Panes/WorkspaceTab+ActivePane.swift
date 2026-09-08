import Foundation

extension WorkspaceTab {
  /// Local focus can briefly refer to the previous tab or a removed split.
  /// Resolve toolbar and keyboard ownership against this tab's current tree.
  public func resolvedActiveLeafId(preferred: UUID?) -> UUID? {
    if let preferred, root.group(id: preferred) != nil { return preferred }
    if root.group(id: activeLeafId) != nil { return activeLeafId }
    return root.allGroups.first?.id
  }
}
