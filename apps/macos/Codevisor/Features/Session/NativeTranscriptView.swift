import AppKit
import CodevisorCore
import QuartzCore
import SwiftUI
import CodevisorUI

/// AppKit only mounts and measures projected rows. The transcript-wide row
/// construction itself lives in CodevisorCore and runs off the UI actor.
typealias TranscriptVirtualRow = TranscriptPresentationRow

struct TranscriptScrollCommand: Equatable {
    var token = 0
}

/// SwiftUI boundary around the AppKit scroll view. All high-frequency geometry
/// stays inside AppKit; SwiftUI receives only boundary transitions and a tiny
/// observation-ignored viewport snapshot.
struct NativeTranscriptView: NSViewRepresentable {
    let rows: [TranscriptVirtualRow]
    let initialState: SessionScrollState?
    let followsLatest: Bool
    let hasOlderHistory: Bool
    let showsOlderHistoryLoadingIndicator: Bool
    let olderHistoryPresentationTarget: TranscriptPaginationPresentationTarget?
    let isLoadingInitialHistory: Bool
    let isPreparingInitialProjection: Bool
    let layoutFingerprint: Int
    let scrollCommand: TranscriptScrollCommand
    let sendAnimationRequest: UserSendAnimationRequest?
    let reduceMotion: Bool
    let claimSendAnimation: @MainActor (UserSendAnimationRequest) -> Bool
    let rowContent: @MainActor (TranscriptVirtualRow) -> AnyView
    let onViewportChange: @MainActor (SessionScrollState) -> Void
    let onBottomStateChange: @MainActor (Bool) -> Void
    let onFollowStateChange: @MainActor (Bool) -> Void
    let onNearTop: @MainActor () -> Void
    let onOlderHistoryPresented: @MainActor (UInt64) -> Void
    var onInitialPresentationReady: (@MainActor () -> Void)? = nil
    /// Called once with the underlying scroll view so the session's focus
    /// controller can park keyboard focus on the chat history when it is
    /// clicked (mirrors the composer's `onTextViewReady`).
    var onScrollViewReady: (@MainActor (NSView) -> Void)? = nil

    func makeNSView(context: Context) -> VirtualizedTranscriptScrollView {
        let view = VirtualizedTranscriptScrollView()
        view.onInitialPresentationReady = reportInitialPresentationReady
        onScrollViewReady?(view)
        view.configure(
            rows: rows,
            initialState: initialState,
            followsLatest: followsLatest,
            hasOlderHistory: hasOlderHistory,
            showsOlderHistoryLoadingIndicator: showsOlderHistoryLoadingIndicator,
            olderHistoryPresentationTarget: olderHistoryPresentationTarget,
            isLoadingInitialHistory: isLoadingInitialHistory,
            isPreparingInitialProjection: isPreparingInitialProjection,
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: sendAnimationRequest,
            reduceMotion: reduceMotion,
            claimSendAnimation: claimSendAnimation,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop,
            onOlderHistoryPresented: onOlderHistoryPresented
        )
        return view
    }

    func updateNSView(_ nsView: VirtualizedTranscriptScrollView, context: Context) {
        nsView.onInitialPresentationReady = reportInitialPresentationReady
        nsView.configure(
            rows: rows,
            initialState: initialState,
            followsLatest: followsLatest,
            hasOlderHistory: hasOlderHistory,
            showsOlderHistoryLoadingIndicator: showsOlderHistoryLoadingIndicator,
            olderHistoryPresentationTarget: olderHistoryPresentationTarget,
            isLoadingInitialHistory: isLoadingInitialHistory,
            isPreparingInitialProjection: isPreparingInitialProjection,
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: sendAnimationRequest,
            reduceMotion: reduceMotion,
            claimSendAnimation: claimSendAnimation,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop,
            onOlderHistoryPresented: onOlderHistoryPresented
        )
        if nsView.isInitialPresentationReady {
            reportInitialPresentationReady()
        }
    }

    static func dismantleNSView(_ nsView: VirtualizedTranscriptScrollView, coordinator: Void) {
        nsView.prepareForDismantle()
    }

    private func reportInitialPresentationReady() {
        guard let onInitialPresentationReady else { return }
        // Readiness can resolve inside updateNSView. Publish after SwiftUI's
        // current update transaction rather than mutating view state from it.
        DispatchQueue.main.async {
            onInitialPresentationReady()
        }
    }
}
