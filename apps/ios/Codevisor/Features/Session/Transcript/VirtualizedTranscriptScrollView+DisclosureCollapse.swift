import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

// MARK: - DisclosureCollapse

extension VirtualizedTranscriptScrollView {
    func performAnchoredDisclosureChange(
        in rowKey: String,
        change: @escaping () -> Void,
    ) {
        guard initialPositionApplied,
            virtualLayout.indexByKey[rowKey] != nil
        else {
            change()
            return
        }
        bottomJumpGate.cancel()
        disclosureAnchorReleaseTask?.cancel()
        let anchor = DisclosureViewportAnchor(
            id: UUID(),
            viewportTop: contentOffset.y,
        )
        disclosureViewportAnchor = anchor
        change()
        disclosureAnchorReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                self?.disclosureViewportAnchor?.id == anchor.id
            else { return }
            self?.disclosureViewportAnchor = nil
            self?.disclosureAnchorReleaseTask = nil
        }
    }

    func cancelDisclosureViewportAnchor() {
        disclosureAnchorReleaseTask?.cancel()
        disclosureAnchorReleaseTask = nil
        disclosureViewportAnchor = nil
    }
}
