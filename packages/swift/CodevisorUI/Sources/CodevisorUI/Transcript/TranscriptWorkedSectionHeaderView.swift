import CodevisorCore
import SwiftUI
import TranscriptKit

public struct TranscriptWorkedRowsPresentation: Sendable {
    public let rows: [TranscriptPresentationRow]
    public let revisionToken: UInt64
}

/// Settled transcript rows change far less often than the active turn. Keep
/// their disclosure projection out of the token-flush path while still
/// invalidating immediately for a user toggle or subagent activity change.
@MainActor
public final class TranscriptWorkedRowsVisibilityCache {
    private struct Key: Equatable {
        let sourceVersion: UInt64
        let disclosureIdentity: ObjectIdentifier
        let disclosureRevision: UInt64
        let runningSubagentToolCallIDs: Set<String>
    }

    private var key: Key?
    private var presentation: TranscriptWorkedRowsPresentation?

    public init() {}

    public func presentSettled(
        _ rows: [TranscriptPresentationRow],
        sourceVersion: UInt64,
        disclosure: TranscriptDisclosureStore,
        runningSubagentToolCallIDs: Set<String>
    ) -> TranscriptWorkedRowsPresentation {
        let currentKey = Key(
            sourceVersion: sourceVersion,
            disclosureIdentity: ObjectIdentifier(disclosure),
            disclosureRevision: disclosure.workedSectionRevision,
            runningSubagentToolCallIDs: runningSubagentToolCallIDs
        )
        if key == currentKey, let presentation { return presentation }
        let presentation = TranscriptWorkedRowsVisibility.present(
            rows,
            disclosure: disclosure,
            activeItem: nil,
            runningSubagentToolCallIDs: runningSubagentToolCallIDs
        )
        key = currentKey
        self.presentation = presentation
        return presentation
    }
}

/// Removes collapsed worked-content rows before they reach the native layout
/// ledger. Headers stay mounted, while expanded sections retain ordinary
/// block-level virtualization regardless of their total length.
@MainActor
public enum TranscriptWorkedRowsVisibility {
    public static func present(
        _ rows: [TranscriptPresentationRow],
        disclosure: TranscriptDisclosureStore,
        activeItem: ConversationItem?,
        runningSubagentToolCallIDs: Set<String>
    ) -> TranscriptWorkedRowsPresentation {
        var result: [TranscriptPresentationRow] = []
        result.reserveCapacity(rows.count)
        var expansion: [TranscriptWorkedSectionIdentity: Bool] = [:]
        var hasher = Hasher()

        for row in rows {
            guard let membership = row.workedSection else {
                result.append(row)
                continue
            }
            switch membership.role {
            case let .header(defaultExpanded, isFixedExpanded):
                let currentTurn = turn(for: row, activeItem: activeItem)
                let keepsRunningSubagentVisible =
                    currentTurn.map { turn in
                        !runningSubagentToolCallIDs.isDisjoint(with: turn.subagents.keys)
                    } ?? false
                let liveIsFixedExpanded =
                    currentTurn.map {
                        $0.isGenerating && !$0.finalTextIsAsserted
                    } ?? isFixedExpanded
                let expanded =
                    liveIsFixedExpanded
                    ? true
                    : disclosure.isExpanded(
                        disclosureKey(for: membership.identity),
                        default: defaultExpanded || keepsRunningSubagentVisible
                    )
                expansion[membership.identity] = expanded
                hasher.combine(membership.identity)
                hasher.combine(expanded)
                result.append(row)
            case .content:
                if expansion[membership.identity] ?? true {
                    result.append(row)
                }
            }
        }

        return TranscriptWorkedRowsPresentation(
            rows: result,
            revisionToken: UInt64(bitPattern: Int64(hasher.finalize()))
        )
    }

    private static func disclosureKey(
        for identity: TranscriptWorkedSectionIdentity
    ) -> TranscriptDisclosureStore.Key {
        switch identity.kind {
        case .planning: .turn(identity.messageID)
        case .implementation: .turnImplementation(identity.messageID)
        }
    }

    private static func turn(
        for row: TranscriptPresentationRow,
        activeItem: ConversationItem?
    ) -> AssistantTurn? {
        switch row.content {
        case let .assistantWorkedHeader(header):
            header.message.turn
        case let .activeWorkedHeader(header):
            if case let .assistant(message)? = activeItem, message.id == header.messageID {
                message.turn
            } else {
                nil
            }
        default:
            nil
        }
    }
}

/// Stable chrome for one virtualized worked section. Its timer is intentionally
/// a plain Text driven by a small task rather than a TimelineView nested in a
/// root that may be reconciled during streaming.
public struct TranscriptWorkedSectionHeaderView: View {
    public let turn: AssistantTurn
    public let messageID: UUID
    public let kind: TranscriptWorkedSectionKind
    public let showsTimer: Bool

    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.runningSubagentToolCallIds) private var runningSubagentToolCallIDs
    @Environment(\.transcriptPerformAnchoredDisclosureChange)
    private var performAnchoredDisclosureChange
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

    public init(
        turn: AssistantTurn,
        messageID: UUID,
        kind: TranscriptWorkedSectionKind,
        showsTimer: Bool
    ) {
        self.turn = turn
        self.messageID = messageID
        self.kind = kind
        self.showsTimer = showsTimer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLiveAndFixedOpen {
                header(showsChevron: false)
            } else {
                Button(action: toggle) {
                    header(showsChevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TranscriptWorkedSectionButtonStyle())
            }
            Divider()
        }
    }

    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

    private var disclosureKey: TranscriptDisclosureStore.Key {
        switch kind {
        case .planning: .turn(messageID)
        case .implementation: .turnImplementation(messageID)
        }
    }

    private var hasRunningSubagent: Bool {
        !runningSubagentToolCallIDs.isDisjoint(with: turn.subagents.keys)
    }

    private var defaultExpanded: Bool {
        (turn.isGenerating && !turn.finalTextIsAsserted) || hasRunningSubagent
    }

    private var isExpanded: Bool {
        store.isExpanded(disclosureKey, default: defaultExpanded)
    }

    private var isLiveAndFixedOpen: Bool {
        turn.isGenerating && !turn.finalTextIsAsserted
    }

    @ViewBuilder
    private func header(showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            label
            if showsChevron {
                TranscriptWorkedDisclosureIndicator(
                    expanded: isExpanded,
                    deferredDetailItemID: turn.hasDeferredWorkedDetails
                        ? turn.deferredDetailItemId
                        : nil
                )
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 18)
        .font(.callout)
        .foregroundStyle(.secondary)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private var label: some View {
        if turn.isGenerating, showsTimer {
            TranscriptWorkingDurationLabel(startedAt: turn.startedAt)
        } else if !showsTimer {
            Text("Planned")
        } else {
            Text(workedTitle)
        }
    }

    private var workedTitle: String {
        guard let duration = turn.duration, duration >= 1 else { return "Worked for a moment" }
        return "Worked for \(Self.format(Int(duration.rounded())))"
    }

    private func toggle() {
        let change = {
            store.setExpanded(disclosureKey, !isExpanded)
            invalidateRowMeasurement?()
        }
        performAnchoredDisclosureChange?(change) ?? change()
    }

    private static func format(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// Worked-section labels should read as stable transcript chrome. Unlike a
/// general button, pressing or hovering the disclosure does not recolor or
/// dim its label.
public struct TranscriptWorkedSectionButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Loads deferred historical work from the chevron slot. Both states occupy
/// the chevron's exact 10×10 footprint, so a network request never creates a
/// temporary transcript row or changes the header's line height.
public struct TranscriptWorkedDisclosureIndicator: View {
    public let expanded: Bool
    public let deferredDetailItemID: String?

    @Environment(\.transcriptController) private var transcriptController
    @State private var loadingItemID: String?

    public init(expanded: Bool, deferredDetailItemID: String?) {
        self.expanded = expanded
        self.deferredDetailItemID = deferredDetailItemID
    }

    public var body: some View {
        Group {
            if loadingItemID == deferredDetailItemID, deferredDetailItemID != nil {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(.secondary)
                    .accessibilityLabel("Loading worked details")
            } else {
                TranscriptDisclosureChevron(expanded: expanded)
            }
        }
        .frame(width: 10, height: 10)
        .task(id: loadRequest) {
            guard let itemID = loadRequest, let transcriptController else {
                loadingItemID = nil
                return
            }
            loadingItemID = itemID
            _ = await transcriptController.loadTranscriptDetails(itemID)
            if loadingItemID == itemID {
                loadingItemID = nil
            }
        }
    }

    private var loadRequest: String? {
        guard expanded, transcriptController != nil else { return nil }
        return deferredDetailItemID
    }
}

private struct TranscriptWorkingDurationLabel: View {
    let startedAt: Date?
    @State private var now = Date()

    var body: some View {
        Text("Working for \(format(elapsedSeconds))")
            .task(id: startedAt) {
                now = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    now = Date()
                }
            }
    }

    private var elapsedSeconds: Int {
        guard let startedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(startedAt)))
    }

    private func format(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
