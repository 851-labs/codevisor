import Foundation

@MainActor
public final class ComposerUndoHistories {
  private let histories = NSMapTable<AnyObject, ComposerUndoHistory>.weakToStrongObjects()

  public init() {}

  public func history(for editor: AnyObject) -> ComposerUndoHistory {
    if let history = histories.object(forKey: editor) { return history }

    let history = ComposerUndoHistory()
    histories.setObject(history, forKey: editor)
    return history
  }
}
