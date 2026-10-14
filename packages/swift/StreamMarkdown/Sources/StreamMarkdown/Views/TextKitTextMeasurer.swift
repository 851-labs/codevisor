#if canImport(AppKit)
  import AppKit
  import QuickLookUI
  import QuartzCore
  import SwiftUI

  @MainActor
  final class TextKitTextMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = StreamingTextLayoutManager()
    private let container = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    private var measuredText: NSAttributedString?
    private var naturalWidthText: NSAttributedString?
    private var cachedNaturalWidth: CGFloat = 1

    init() {
      storage.addLayoutManager(layoutManager)
      container.lineFragmentPadding = 0
      container.widthTracksTextView = false
      container.heightTracksTextView = false
      layoutManager.addTextContainer(container)
    }

    func naturalWidth(for text: NSAttributedString) -> CGFloat {
      if naturalWidthText === text { return cachedNaturalWidth }
      if measuredText !== text {
        storage.setAttributedString(text)
        measuredText = text
      }
      container.containerSize = NSSize(
        width: 1_000_000,
        height: CGFloat.greatestFiniteMagnitude
      )
      layoutManager.ensureLayout(for: container)
      naturalWidthText = text
      cachedNaturalWidth = max(1, ceil(layoutManager.usedRect(for: container).width))
      return cachedNaturalWidth
    }
  }

#endif
