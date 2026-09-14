import Foundation

/// Window-local focus ownership. Cached containers may keep observing their
/// chat, but only a visible container in the selected workspace can read it.
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

  /// SwiftUI can mount a new container before removing the old one, even
  /// for the same chat. Release the publishing surface, not the chat id.
  public mutating func clear(sourceId: UUID) {
    guard self.sourceId == sourceId else { return }
    self.sourceId = nil
    session = nil
  }
}
