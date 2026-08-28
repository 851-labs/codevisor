import CodevisorCore
import SwiftUI
import UIKit

/// The only controller SwiftUI installs for a transcript. It is a real UIKit
/// containment boundary: row hosting controllers are descendants of this
/// controller, not siblings injected into the navigation destination.
@MainActor
final class TranscriptViewController: UIViewController {
    private let transcriptScrollView = VirtualizedTranscriptScrollView()

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root

        transcriptScrollView.hostingParent = self
        transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(transcriptScrollView)
        NSLayoutConstraint.activate([
            transcriptScrollView.topAnchor.constraint(equalTo: root.topAnchor),
            transcriptScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcriptScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcriptScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    func configure(
        rows: [TranscriptVirtualRow],
        activeRows: [TranscriptVirtualRow],
        activeRowsVersion: UInt64,
        rowsVersion: UInt64,
        initialState: SessionScrollState?,
        followsLatest: Bool,
        hasOlderHistory: Bool,
        showsOlderHistoryLoadingIndicator: Bool,
        olderHistoryPresentationTarget: TranscriptPaginationPresentationTarget?,
        isLoadingInitialHistory: Bool,
        isPreparingInitialProjection: Bool,
        layoutFingerprint: Int,
        scrollCommand: TranscriptScrollCommand,
        sendAnimationRequest: UserSendAnimationRequest?,
        sendAnimationSourceFrame: CGRect?,
        presentationRole: TranscriptPresentationRole,
        reduceMotion: Bool,
        scrollIndicatorBottomInset: CGFloat,
        claimSendAnimation: @escaping (UserSendAnimationRequest) -> Bool,
        onSendAnimationStarted: (
            (
                UserSendAnimationRequest,
                TranscriptSendAnimationTarget
            ) -> Bool
        )?,
        onSendAnimationCompleted: @escaping (UserSendAnimationRequest) -> Void,
        rowContent: @escaping (TranscriptVirtualRow) -> AnyView,
        onViewportChange: @escaping (SessionScrollState) -> Void,
        onBottomStateChange: @escaping (Bool) -> Void,
        onFollowStateChange: @escaping (Bool) -> Void,
        onNearTop: @escaping () -> Void,
        onOlderHistoryPresented: @escaping (UInt64) -> Void,
    ) {
        loadViewIfNeeded()
        transcriptScrollView.configure(
            rows: rows,
            activeRows: activeRows,
            activeRowsVersion: activeRowsVersion,
            rowsVersion: rowsVersion,
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
            sendAnimationSourceFrame: sendAnimationSourceFrame,
            presentationRole: presentationRole,
            reduceMotion: reduceMotion,
            scrollIndicatorBottomInset: scrollIndicatorBottomInset,
            claimSendAnimation: claimSendAnimation,
            onSendAnimationStarted: onSendAnimationStarted,
            onSendAnimationCompleted: onSendAnimationCompleted,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop,
            onOlderHistoryPresented: onOlderHistoryPresented,
        )
    }

    func prepareForDismantle() {
        transcriptScrollView.prepareForDismantle()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        transcriptScrollView.discardParkedHosts()
    }
}
