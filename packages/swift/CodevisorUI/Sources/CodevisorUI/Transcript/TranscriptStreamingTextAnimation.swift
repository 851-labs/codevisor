import CodevisorCore
import Foundation
import StreamMarkdown

/// Stable identities shared by the macOS and iOS transcript renderers. Main
/// turn text and each subagent bucket use separate namespaces because their
/// reducer-local fallback ids (`t0`, `t1`, …) may otherwise collide.
public enum TranscriptStreamingTextIdentity {
    public static func main(turnID: UUID, entryID: String) -> String {
        "\(turnID.uuidString):main:\(entryID)"
    }

    /// Final answers may be split around inline attachment previews. Each
    /// Markdown slice owns a separate native streaming surface, so its
    /// identity must include the same segment index in both the navigation
    /// baseline and the platform renderers.
    public static func mainResponseSegment(
        turnID: UUID,
        entryID: String,
        segmentIndex: Int
    ) -> String {
        main(turnID: turnID, entryID: "\(entryID):\(segmentIndex)")
    }

    public static func subagent(
        turnID: UUID,
        parentToolCallID: String,
        entryID: String
    ) -> String {
        "\(turnID.uuidString):subagent:\(parentToolCallID):\(entryID)"
    }

    /// Every text stream that predates this turn view's mount. Seeding these
    /// as settled is the navigation boundary: only entries first created
    /// afterward may animate their initial content.
    public static func settledStreamIDs(turn: AssistantTurn, turnID: UUID) -> [String] {
        var result = turn.entries.compactMap { entry -> String? in
            guard case let .text(id, _) = entry else { return nil }
            return main(turnID: turnID, entryID: id)
        }
        if let finalTextIndex = turn.finalTextIndex,
            case let .text(entryID, markdown) = turn.entries[finalTextIndex]
        {
            let segments = assistantMarkdownSegments(
                markdown,
                attachments: turn.attachments,
                includeServerPaths: !turn.isGenerating
            )
            for (index, segment) in segments.enumerated() {
                guard case let .markdown(value) = segment, !value.isEmpty else { continue }
                result.append(
                    mainResponseSegment(
                        turnID: turnID,
                        entryID: entryID,
                        segmentIndex: index
                    ))
            }
        }
        for (parentToolCallID, transcript) in turn.subagents {
            result.append(
                contentsOf: transcript.entries.compactMap { entry -> String? in
                    guard case let .text(id, _) = entry else { return nil }
                    return subagent(
                        turnID: turnID,
                        parentToolCallID: parentToolCallID,
                        entryID: id
                    )
                })
        }
        return result
    }
}

public extension StreamingTextAnimationPresentation {
    func establishBaseline(settling turn: AssistantTurn, turnID: UUID) {
        establishBaseline {
            TranscriptStreamingTextIdentity.settledStreamIDs(
                turn: turn,
                turnID: turnID
            )
        }
    }
}
