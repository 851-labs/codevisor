import AppKit
import SwiftUI

@MainActor
final class TranscriptAddToChatButton: NSHostingView<TranscriptAddToChatButtonLabel> {
  init(action: @escaping () -> Void) {
    super.init(rootView: TranscriptAddToChatButtonLabel(action: action))
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
}

struct TranscriptAddToChatButtonLabel: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Add to Chat", systemImage: "text.quote")
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .capsule)
    .padding(4)
    .help("Quote the selected text in your next message")
  }
}
