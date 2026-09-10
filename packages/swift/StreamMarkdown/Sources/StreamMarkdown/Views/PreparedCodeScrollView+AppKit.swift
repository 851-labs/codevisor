#if canImport(AppKit)
  import AppKit
  import SwiftUI

  /// Uses the same axis routing as other transcript code blocks. The native
  /// text view owns the prepared layout and keeps selection while scrolling.
  struct PreparedCodeScrollView: NSViewRepresentable {
    let layout: PreparedNativeTextLayout

    func makeNSView(context: Context) -> TranscriptHorizontalScrollView {
      let scrollView = TranscriptHorizontalScrollView()
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      scrollView.hasHorizontalScroller = false
      scrollView.hasVerticalScroller = false
      scrollView.horizontalScrollElasticity = .automatic
      scrollView.verticalScrollElasticity = .none
      scrollView.automaticallyAdjustsContentInsets = false

      let textView = SelectableTextKitView(preparedLayout: layout)
      textView.textContainerInset = NSSize(width: 10, height: 10)
      textView.setFrameSize(contentSize)
      scrollView.documentView = textView
      return scrollView
    }

    func updateNSView(_ view: TranscriptHorizontalScrollView, context: Context) {
      guard let textView = view.documentView as? SelectableTextKitView else { return }
      textView.adoptPreparedLayout(layout)
      textView.setFrameSize(contentSize)
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize, nsView: TranscriptHorizontalScrollView, context: Context
    ) -> CGSize? {
      CGSize(width: proposal.width ?? contentSize.width, height: contentSize.height)
    }

    private var contentSize: CGSize {
      CGSize(width: layout.size.width + 20, height: layout.size.height + 20)
    }
  }
#endif
