import AppKit
import SwiftUI

@MainActor
final class TranscriptAddToChatButton: NSHostingView<TranscriptAddToChatButtonLabel> {
  private let shortcut: TranscriptAddToChatShortcut?

  init(shortcut: TranscriptAddToChatShortcut?, action: @escaping () -> Void) {
    self.shortcut = shortcut
    super.init(rootView: TranscriptAddToChatButtonLabel(shortcutHint: shortcut?.hint, action: action))
    isHidden = true
  }

  @available(*, unavailable)
  required init(rootView: TranscriptAddToChatButtonLabel) {
    fatalError("init(rootView:) has not been implemented")
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(at origin: NSPoint) {
    setFrameSize(fittingSize)
    setFrameOrigin(origin)
    isHidden = false
  }

  func hide() {
    isHidden = true
  }

  func performShortcut(_ event: NSEvent) -> Bool {
    guard !isHidden, shortcut?.matches(event) == true else { return false }

    rootView.action()
    return true
  }
}

struct TranscriptAddToChatButtonLabel: View {
  let shortcutHint: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Label("Add to Chat", systemImage: "text.quote")
          .font(.callout.weight(.medium))
        if let shortcutHint {
          Text(shortcutHint)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding(4)
    .help(helpText)
  }

  private var helpText: String {
    guard let shortcutHint else { return "Quote the selected text in your next message" }
    return "Quote the selected text in your next message (\(shortcutHint))"
  }
}
