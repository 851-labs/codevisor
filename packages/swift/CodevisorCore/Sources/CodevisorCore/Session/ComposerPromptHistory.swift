import Foundation
import TranscriptKit

/// Terminal-style ↑/↓ recall of the prompts already sent in one chat.
///
/// The cursor is a value the composer keeps between key presses. Stepping
/// back from the draft remembers it, so stepping forward past the newest
/// prompt puts the unsent text back. A cursor is tied to the history it was
/// started from: once a new prompt is sent, the next ↑ starts over from the
/// newest prompt instead of resuming a stale position.
public struct ComposerPromptHistory: Equatable, Sendable {
  /// Sent prompts, oldest first.
  public let entries: [String]
  /// Position in `entries`; `entries.count` means "back at the draft".
  public private(set) var index: Int
  /// The composer text from before the first recall.
  public private(set) var draft: String

  /// Starts a navigation session, or nil when there is nothing to recall.
  public init?(entries: [String], draft: String) {
    guard !entries.isEmpty else { return nil }
    self.entries = entries
    self.index = entries.count
    self.draft = draft
  }

  /// The prompt before the current position, or nil at the oldest prompt.
  public mutating func previous() -> String? {
    guard index > 0 else { return nil }
    index -= 1
    return entries[index]
  }

  /// The prompt after the current position, the saved draft when stepping
  /// past the newest prompt, or nil when already at the draft.
  public mutating func next() -> String? {
    guard index < entries.count else { return nil }
    index += 1
    return index == entries.count ? draft : entries[index]
  }

  /// One ↑ (`older`) or ↓ press against the composer's kept cursor.
  /// `fresh` is a cursor started from the chat's current history and draft.
  /// A kept cursor is replaced by it when another prompt was sent since it
  /// started (so ↑ never skips the newest prompt), or on ↑ from the draft
  /// (so the text typed since then becomes the draft ↓ restores).
  public static func step(
    _ cursor: inout ComposerPromptHistory?,
    fresh: ComposerPromptHistory?,
    older: Bool
  ) -> String? {
    if cursor?.entries != fresh?.entries || (older && cursor?.isAtDraft == true) {
      cursor = fresh
    }
    return older ? cursor?.previous() : cursor?.next()
  }

  var isAtDraft: Bool { index == entries.count }

  /// The chat's own sent prompts, oldest first. Blank prompts are skipped
  /// and consecutive repeats collapse to one entry, like shell history.
  /// Prompts whose text the server truncated (`textResource`) are skipped:
  /// recalling a partial prompt and sending it would silently lose content.
  public static func entries(
    in conversation: [ConversationItem],
    pending: UserMessage? = nil
  ) -> [String] {
    var messages: [UserMessage] = conversation.compactMap {
      if case let .user(message) = $0 { return message }
      return nil
    }
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
  /// One ↑ (`older`) or ↓ press of prompt recall. Writes the recalled text
  /// (or the restored draft) into the composer and returns where the caret
  /// goes, or nil when nothing changed. The conversation is read on key
  /// press only, so the composer does not observe it while typing.
  public func recallPrompt(_ cursor: inout ComposerPromptHistory?, older: Bool) -> NSRange? {
    // The goal editor holds the goal objective, not a prompt.
    guard !isGoalEditing else {
      cursor = nil
      return nil
    }
    let fresh = ComposerPromptHistory(
      entries: ComposerPromptHistory.entries(in: conversation, pending: pendingUserMessage),
      draft: composerText
    )
    guard let text = ComposerPromptHistory.step(&cursor, fresh: fresh, older: older) else { return nil }
    composerText = text
    // Older prompts put the caret at the start so repeated ↑ keeps
    // stepping back; newer ones put it at the end for repeated ↓.
    return NSRange(location: older ? 0 : (text as NSString).length, length: 0)
  }
}
