import AppKit
import SwiftUI

@MainActor
final class TranscriptQuoteNotFoundNotice: NSHostingView<TranscriptQuoteNotFoundLabel> {
  private static let visibleDuration: Duration = .seconds(2)
  private var dismissTask: Task<Void, Never>?

  init() {
    super.init(rootView: TranscriptQuoteNotFoundLabel())
    isHidden = true
  }

  @available(*, unavailable)
  required init(rootView: TranscriptQuoteNotFoundLabel) {
    fatalError("init(rootView:) has not been implemented")
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_: NSPoint) -> NSView? { nil }

  func show(centeredAtTopOf region: NSRect) {
    let size = fittingSize
    frame = NSRect(x: region.midX - size.width / 2, y: region.minY + 12, width: size.width, height: size.height)
    alphaValue = 1
    isHidden = false
    dismissTask?.cancel()
    dismissTask = Task { [weak self] in
      try? await Task.sleep(for: Self.visibleDuration)
      guard !Task.isCancelled else { return }
      self?.isHidden = true
    }
  }
}

struct TranscriptQuoteNotFoundLabel: View {
  var body: some View {
    Text("Original message not found")
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .glassEffect(.regular, in: .capsule)
      .padding(4)
  }
}
