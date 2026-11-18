import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
public final class ComposerViewState {
  public var slashSelection = 0
  public var promptHistory: ComposerPromptHistory?
  public var isSlashMenuDismissed = false
  public var didAcceptSubmission = false
  private var resolvingQuestion: AnyHashable?
  private var selection = NSRange(location: 0, length: 0)
  private var selectionDraft: String?
  @ObservationIgnored public let undo = ComposerUndoHistories()

  private static let states = NSMapTable<SessionController, ComposerViewState>.weakToStrongObjects()

  public init() {}

  public static func of(_ chat: SessionController) -> ComposerViewState {
    if let state = states.object(forKey: chat) { return state }

    let state = ComposerViewState()
    states.setObject(state, forKey: chat)
    return state
  }

  public func selection(in draft: String) -> NSRange {
    selectionDraft == draft ? selection : NSRange(location: (draft as NSString).length, length: 0)
  }

  public func select(_ range: NSRange, in draft: String) {
    if selection != range { selection = range }
    if selectionDraft != draft { selectionDraft = draft }
  }

  public func isResolving(_ question: AnyHashable?) -> Bool {
    question != nil && resolvingQuestion == question
  }

  public func setResolving(_ isResolving: Bool, question: AnyHashable) {
    if isResolving {
      resolvingQuestion = question
    } else if resolvingQuestion == question {
      resolvingQuestion = nil
    }
  }
}
