import AppKit

/// Common lifecycle understood by the transcript virtualizer.
///
/// Interactive rows use ``TranscriptRowHost`` and SwiftUI. Settled Markdown
/// uses ``TranscriptMarkdownRowHost`` and never constructs a hosting
/// controller. Keeping the boundary here prevents renderer-specific work from
/// leaking back into scroll scheduling.
@MainActor
class TranscriptMountedRowHost: NSView {
    var onHeightChange: ((CGFloat) -> Void)?

    var isPresentationReady: Bool { false }
    var isAttachmentGeometryReady: Bool { true }
    var needsRunwayPreparation: Bool { !isPresentationReady }

    func prepareForMountedRow() {}
    func syncContentWidth() -> Bool { false }
    func prepareForImmediatePresentation() {}
    func requestContentMeasurement(forceReport _: Bool = true) {}

    @discardableResult
    func setAttachmentGeometryReady(_: Bool) -> Bool { false }
}
