#if canImport(AppKit)
  import AppKit
  import SwiftUI

  /// Keeps native table selection and TSV copying while mounting a TextKit
  /// stack whose attributes and geometry were prepared off the UI actor.
  struct PreparedTableNativeView: NSViewRepresentable {
    let layout: PreparedNativeTextLayout
    let borderColor: Color
    @Environment(\.markdownLinkAction) private var linkAction

    func makeNSView(context: Context) -> TableBleedContainer {
      let textView = TableTextView(frame: CGRect(origin: .zero, size: layout.size), textContainer: layout.container)
      textView.preparedWidth = layout.size.width
      textView.isEditable = false
      textView.isSelectable = true
      textView.drawsBackground = false
      textView.textContainerInset = .zero
      textView.isVerticallyResizable = false
      textView.isHorizontallyResizable = false
      textView.focusRingType = .none
      textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
      let container = TableBleedContainer(tableTextView: textView)
      updateNSView(container, context: context)
      return container
    }

    func updateNSView(_ view: TableBleedContainer, context: Context) {
      let textView = view.scrollView.tableTextView
      if textView.layoutManager !== layout.manager {
        let selection = textView.selectedRange()
        textView.replaceTextContainer(layout.container)
        textView.preparedWidth = layout.size.width
        textView.setFrameSize(layout.size)
        if NSMaxRange(selection) <= layout.text.length { textView.setSelectedRange(selection) }
        view.needsLayout = true
      }
      textView.linkAction = linkAction
      view.scrollView.setBorderColor(NSColor(borderColor))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TableBleedContainer, context: Context) -> CGSize? {
      CGSize(width: proposal.width ?? layout.size.width, height: layout.size.height)
    }
  }
#endif
