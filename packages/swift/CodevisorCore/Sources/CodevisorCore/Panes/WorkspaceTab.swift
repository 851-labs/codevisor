import Foundation

public struct WorkspaceTab: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public var customTitle: String?
  public var root: SplitNode
  public var activeLeafId: UUID
  public var isPreview: Bool

  public init(
    id: UUID = UUID(),
    customTitle: String? = nil,
    root: SplitNode,
    activeLeafId: UUID? = nil,
    isPreview: Bool = false
  ) {
    self.id = id
    self.customTitle = customTitle
    self.root = root
    self.isPreview = isPreview
    self.activeLeafId =
      activeLeafId.flatMap { root.group(id: $0) != nil ? $0 : nil }
      ?? root.allGroups.first?.id
      ?? UUID()
  }

  private enum CodingKeys: String, CodingKey { case id, customTitle, root, activeLeafId, isPreview }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    isPreview = try container.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false
    let decodedRoot = try container.decode(SplitNode.self, forKey: .root)
    root = decodedRoot
    let decoded = try container.decodeIfPresent(UUID.self, forKey: .activeLeafId)
    activeLeafId =
      decoded.flatMap { decodedRoot.group(id: $0) != nil ? $0 : nil }
      ?? decodedRoot.allGroups.first?.id
      ?? UUID()
  }

  public static func placeholder() -> WorkspaceTab {
    WorkspaceTab(root: .leaf(.centerInitialWithoutChat()))
  }

  public var isPlaceholder: Bool {
    root.allGroups.allSatisfy { group in group.state.panes.allSatisfy { $0.kind == .newTab } }
  }

  public func resolvedActiveLeafId(preferred: UUID?) -> UUID? {
    if let preferred, root.group(id: preferred) != nil { return preferred }
    if root.group(id: activeLeafId) != nil { return activeLeafId }
    return root.allGroups.first?.id
  }

  public func displayTitle(for pane: PaneDescriptorState?, chatTitle: String?) -> String {
    if pane?.kind == .chat { return chatTitle ?? pane?.name ?? "New Chat" }
    return customTitle ?? pane?.displayName ?? "New Tab"
  }
}
