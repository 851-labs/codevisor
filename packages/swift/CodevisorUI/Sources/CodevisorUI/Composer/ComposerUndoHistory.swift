import Foundation

@MainActor
public final class ComposerUndoHistory {
  public let manager = UndoManager()
  private var text: String?

  public init() {}

  public func leave(showing text: String) {
    self.text = text
  }

  public func enter(showing text: String) {
    if self.text != text { forget() }
    self.text = text
  }

  public func forget() {
    manager.removeAllActions()
  }
}
