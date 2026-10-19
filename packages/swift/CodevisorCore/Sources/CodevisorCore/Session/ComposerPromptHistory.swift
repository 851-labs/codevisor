import Foundation
import TranscriptKit

public struct ComposerPromptHistory: Equatable, Sendable {
  public let entries: [String]
  public private(set) var index: Int

  public init?(entries: [String]) {
    guard !entries.isEmpty else { return nil }
    self.entries = entries
    self.index = entries.count
  }

  public mutating func previous() -> String? {
    guard index > 0 else { return nil }
    index -= 1
    return entries[index]
  }

  public mutating func next() -> String? {
    guard index < entries.count else { return nil }
    index += 1
    return index == entries.count ? "" : entries[index]
  }

  public static func step(
    _ cursor: inout ComposerPromptHistory?,
    fresh: ComposerPromptHistory?,
    composerText: String,
    hasAttachments: Bool,
    older: Bool
  ) -> String? {
    guard !hasAttachments else {
      cursor = nil
      return nil
    }
    if !(cursor?.isShowing(composerText, from: fresh) ?? false) {
      guard composerText.isEmpty else {
        cursor = nil
        return nil
      }
      cursor = fresh
    }
    return older ? cursor?.previous() : cursor?.next()
  }

  private func isShowing(_ text: String, from fresh: ComposerPromptHistory?) -> Bool {
    entries == fresh?.entries && index < entries.count && entries[index] == text
  }

  public static func entries(
    in conversation: [ConversationItem],
    pending: UserMessage? = nil
  ) -> [String] {
    var messages: [UserMessage] = conversation.compactMap(\.userPrompt)
    if let pending, !messages.contains(where: { $0.id == pending.id }) {
      messages.append(pending)
    }
    var entries: [String] = []
    for message in messages where message.textResource == nil {
      let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, entries.last != text else { continue }
      entries.append(text)
    }
    return entries
  }
}

extension SessionController {
  public func recallPrompt(_ cursor: inout ComposerPromptHistory?, older: Bool) -> NSRange? {
    guard !isGoalEditing else {
      cursor = nil
      return nil
    }
    let fresh = ComposerPromptHistory(
      entries: ComposerPromptHistory.entries(in: conversation, pending: pendingUserMessage)
    )
    guard
      let text = ComposerPromptHistory.step(
        &cursor,
        fresh: fresh,
        composerText: composerText,
        hasAttachments: !composerAttachments.isEmpty,
        older: older
      )
    else { return nil }
    composerText = text
    return NSRange(location: older ? 0 : (text as NSString).length, length: 0)
  }
}
