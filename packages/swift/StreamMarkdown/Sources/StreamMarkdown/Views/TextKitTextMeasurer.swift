// The AppKit/TextKit rendering layer. iOS uses the matching UIKit/TextKit
// implementation in `SelectableTextView+UIKit.swift`.
#if canImport(AppKit)
    import AppKit
    import QuickLookUI
    import QuartzCore
    import SwiftUI

    /// Scratch TextKit stack used only for SwiftUI size probes. Probes never
    /// resize or relayout the displayed `NSTextView`, so selection and scroll state
    /// cannot be disturbed by measurement.
    @MainActor
    final class TextKitTextMeasurer {
        private let storage = NSTextStorage()
        private let layoutManager = StreamingTextLayoutManager()
        private let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        private var measuredText: NSAttributedString?
        private var measuredWidth: CGFloat = -1
        private var measuredHeight: CGFloat = 1
        private var naturalWidthText: NSAttributedString?
        private var cachedNaturalWidth: CGFloat = 1

        init() {
            storage.addLayoutManager(layoutManager)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layoutManager.addTextContainer(container)
        }

        func height(for text: NSAttributedString, width: CGFloat) -> CGFloat {
            let width = max(1, width)
            if measuredText === text, abs(measuredWidth - width) <= 0.25 {
                return measuredHeight
            }
            if measuredText !== text {
                storage.setAttributedString(text)
                measuredText = text
            }
            container.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: container)
            measuredWidth = width
            measuredHeight = max(1, ceil(layoutManager.usedRect(for: container).height))
            return measuredHeight
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
            // The next height query must lay out at its concrete wrapping width.
            measuredWidth = -1
            return cachedNaturalWidth
        }
    }

#endif
