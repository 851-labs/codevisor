import Foundation

public struct SessionAttentionWorkspaceFocus {
  public private(set) var workspaceId: UUID?
  public private(set) var session: SessionAttentionFocus?
  private var sourceId: UUID?

  public init() {}

  public mutating func selectWorkspace(_ id: UUID?) {
    guard workspaceId != id else { return }
    workspaceId = id
    session = nil
    sourceId = nil
  }

  public mutating func update(
    sourceId: UUID,
    workspaceId: UUID,
    isVisible: Bool,
    session: SessionAttentionFocus?
  ) {
    guard isVisible, self.workspaceId == workspaceId else {
      clear(sourceId: sourceId)
      return
    }
    self.sourceId = sourceId
    self.session = session
  }

  public mutating func clear(sourceId: UUID) {
    guard self.sourceId == sourceId else { return }
    self.sourceId = nil
    session = nil
  }
}
