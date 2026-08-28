import Foundation

/// Gates native Markdown blocks behind the streamed content that precedes
/// them. Text segments before the first pending block may mount and schedule
/// their word fades; the block and every later segment remain unmounted until
/// that prefix has finished entering.
///
/// The sequence keeps only semantic block identities. Code and table content
/// may grow on every provider flush without replaying the block entrance, and
/// a navigation baseline can settle every block that was already present.
@MainActor
final class StreamingMarkdownBlockEntranceSequence {
    enum BeginRevealResult: Equatable {
        case started
        case resumed
        case unavailable
    }

    struct Resolution: Equatable {
        let visibleSegmentCount: Int
        let pendingBlockID: String?
        let revealingSegmentIndex: Int?

        var hasActiveEntrance: Bool { pendingBlockID != nil }
    }

    private struct BlockPosition {
        let id: String
        let segmentIndex: Int
    }

    private var revealedBlockIDs: Set<String> = []
    private var revealingBlockID: String?

    func resolve(
        segments: [MarkdownSegment],
        animationPath: String,
        animationEnabled: Bool,
        animatesInitialContent: Bool,
        reduceMotion: Bool
    ) -> Resolution {
        let blocks = Self.blockPositions(in: segments, animationPath: animationPath)
        let currentBlockIDs = Set(blocks.map(\.id))

        if let revealingBlockID, !currentBlockIDs.contains(revealingBlockID) {
            self.revealingBlockID = nil
        }

        guard animationEnabled, animatesInitialContent, !reduceMotion else {
            revealedBlockIDs.formUnion(currentBlockIDs)
            revealingBlockID = nil
            return Resolution(
                visibleSegmentCount: segments.count,
                pendingBlockID: nil,
                revealingSegmentIndex: nil
            )
        }

        guard let pending = blocks.first(where: { !revealedBlockIDs.contains($0.id) }) else {
            return Resolution(
                visibleSegmentCount: segments.count,
                pendingBlockID: nil,
                revealingSegmentIndex: nil
            )
        }

        if let revealingBlockID, revealingBlockID != pending.id {
            self.revealingBlockID = nil
        }
        let isRevealing = self.revealingBlockID == pending.id
        return Resolution(
            visibleSegmentCount: pending.segmentIndex + (isRevealing ? 1 : 0),
            pendingBlockID: pending.id,
            revealingSegmentIndex: isRevealing ? pending.segmentIndex : nil
        )
    }

    /// Starts a block entrance or resumes one whose view task was cancelled by
    /// a temporary disappearance. Resumption preserves the original timeline
    /// deadline instead of replaying the fade.
    func beginReveal(blockID: String) -> BeginRevealResult {
        guard !revealedBlockIDs.contains(blockID) else { return .unavailable }
        if revealingBlockID == blockID { return .resumed }
        guard revealingBlockID == nil else { return .unavailable }
        revealingBlockID = blockID
        return .started
    }

    func finishReveal(blockID: String) -> Bool {
        guard revealingBlockID == blockID else { return false }
        revealedBlockIDs.insert(blockID)
        revealingBlockID = nil
        return true
    }

    private static func blockPositions(
        in segments: [MarkdownSegment],
        animationPath: String
    ) -> [BlockPosition] {
        segments.enumerated().compactMap { index, segment in
            guard case let .block(block) = segment else { return nil }
            return BlockPosition(
                id: "\(animationPath).\(index).\(kind(of: block))",
                segmentIndex: index
            )
        }
    }

    private static func kind(of block: MarkdownBlock) -> String {
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList: "text"
        case .codeBlock: "code"
        case .list: "list"
        case .blockQuote: "quote"
        case .table: "table"
        case .thematicBreak: "rule"
        }
    }
}
