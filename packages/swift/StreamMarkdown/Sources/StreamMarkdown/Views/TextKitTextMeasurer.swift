// The AppKit/TextKit rendering layer. iOS uses the matching UIKit/TextKit
// implementation in `SelectableTextView+UIKit.swift`.
#if canImport(AppKit)
    import AppKit
    import QuickLookUI
    import QuartzCore
    import SwiftUI

    /// Lazily-created scratch TextKit stack used only by views that need their
    /// unwrapped natural width. Height probes use the displayed TextKit stack so
    /// rendering can reuse the same glyph and line-fragment layout.
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
