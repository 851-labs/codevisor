#if canImport(AppKit)
  import AppKit
  import SwiftUI

  @MainActor
  final class HeightLimitedScrollContainer: TranscriptHorizontalScrollView {
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var contentHeight: CGFloat = 1

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      drawsBackground = false
      borderType = .noBorder
      hasHorizontalScroller = false
      hasVerticalScroller = false
      autohidesScrollers = true
      scrollerStyle = .overlay
      horizontalScrollElasticity = .none
      automaticallyAdjustsContentInsets = false
      host.sizingOptions = []
      documentView = host.view
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    func setContent(_ content: some View) {
      host.rootView = AnyView(
        content
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
            self?.contentHeightChanged(height)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
      )
    }

    func fit(toWidth proposedWidth: CGFloat?) -> CGSize? {
      guard let width = proposedWidth else { return nil }

      let measured = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
      contentHeight = max(1, ceil(measured.height))
      fitDocument(toWidth: width)
      return CGSize(width: width, height: min(contentHeight, maxHeight))
    }

    override func layout() {
      super.layout()
      fitDocument(toWidth: bounds.width)
    }

    private func contentHeightChanged(_ height: CGFloat) {
      let height = max(1, ceil(height))
      guard abs(height - contentHeight) > 0.5 else { return }

      contentHeight = height
      fitDocument(toWidth: bounds.width)
      invalidateIntrinsicContentSize()
    }

    private func fitDocument(toWidth width: CGFloat) {
      let documentSize = CGSize(width: max(1, width), height: contentHeight)
      if host.view.frame.size != documentSize {
        host.view.setFrameSize(documentSize)
      }
      let scrollsVertically = contentHeight > maxHeight + 0.5
      if hasVerticalScroller != scrollsVertically {
        hasVerticalScroller = scrollsVertically
      }
      reflectScrolledClipView(contentView)
    }
  }
#endif
