import AppKit

struct TranscriptAddToChatShortcut {
  let hint: String
  let matches: (NSEvent) -> Bool
}
