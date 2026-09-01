import AppKit
import CodevisorCore
import QuartzCore
import StreamMarkdown
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
    let presentationSurface: TranscriptPresentationSurface
    let sessionController: SessionController
    let rows: [TranscriptVirtualRow]
    let activeRows: [TranscriptVirtualRow]
    let activeRowsVersion: UInt64
    let rowsVersion: UInt64
    let projectionRevision: UInt64
    let initialState: SessionScrollState?
    let followsLatest: Bool
    let hasOlderHistory: Bool
    let showsOlderHistoryLoadingIndicator: Bool
    let isLoadingInitialHistory: Bool
    let isPreparingInitialProjection: Bool
    let isActiveProjectionPending: Bool
    let layoutFingerprint: Int
    let scrollCommand: TranscriptScrollCommand
    let sendAnimationRequest: UserSendAnimationRequest?
    let reduceMotion: Bool
    let markdownRowStyle: TranscriptMarkdownRowStyle
    let claimSendAnimation: @MainActor (UserSendAnimationRequest) -> Bool
    let rowContent: @MainActor (TranscriptVirtualRow) -> AnyView
    let onViewportChange: @MainActor (SessionScrollState) -> Void
    let onBottomStateChange: @MainActor (Bool) -> Void
    let onFollowStateChange: @MainActor (Bool) -> Void
    let onNearTop: @MainActor () -> Void
    var onInitialPresentationReady: (@MainActor () -> Void)? = nil
    /// Called once with the underlying scroll view so the session's focus
    /// controller can park keyboard focus on the chat history when it is
    /// clicked (mirrors the composer's `onTextViewReady`).
    var onScrollViewReady: (@MainActor (NSView) -> Void)? = nil

    final class SurfaceContainerView: NSView {
        var presentationSurface: TranscriptPresentationSurface?
        var reclaimSurface: (() -> Void)?

        override func layout() {
            super.layout()
            reclaimSurface?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                reclaimSurface?()
            }
        }

        func releaseSurface() {
            guard let presentationSurface else {
                reclaimSurface = nil
                return
            }
            if let scrollView = presentationSurface.existingScrollView,
                scrollView.superview === self
            {
                scrollView.prepareForDismantle()
                scrollView.removeFromSuperview()
            }
            self.presentationSurface = nil
            reclaimSurface = nil
        }

        func relinquishSurface(_ surface: TranscriptPresentationSurface) {
            guard presentationSurface === surface else { return }
            presentationSurface = nil
            reclaimSurface = nil
        }
    }

    func makeNSView(context: Context) -> SurfaceContainerView {
        let container = SurfaceContainerView()
        let scrollView = presentationSurface.ensureScrollView()
        container.presentationSurface = presentationSurface
        container.reclaimSurface = { [weak container] in
            guard let container else { return }
            Self.attach(presentationSurface, to: container)
        }
        scrollView.prepareForPresentationAttachment()
        Self.attach(presentationSurface, to: container)
        configure(scrollView)
        onScrollViewReady?(scrollView)
        return container
    }

    func updateNSView(_ container: SurfaceContainerView, context: Context) {
        if container.presentationSurface !== presentationSurface {
            container.releaseSurface()
            container.presentationSurface = presentationSurface
            presentationSurface.ensureScrollView().prepareForPresentationAttachment()
        }
        container.reclaimSurface = { [weak container] in
            guard let container else { return }
            Self.attach(presentationSurface, to: container)
        }
        Self.attach(presentationSurface, to: container)
        configure(presentationSurface.ensureScrollView())
    }

    static func dismantleNSView(_ container: SurfaceContainerView, coordinator: Void) {
        container.releaseSurface()
    }

    private func configure(_ view: VirtualizedTranscriptScrollView) {
        view.onInitialPresentationReady = reportInitialPresentationReady
        view.configure(
            sessionController: sessionController,
            rows: rows,
            activeRows: activeRows,
            activeRowsVersion: activeRowsVersion,
            rowsVersion: rowsVersion,
            projectionRevision: projectionRevision,
            initialState: initialState,
            followsLatest: followsLatest,
            hasOlderHistory: hasOlderHistory,
            showsOlderHistoryLoadingIndicator: showsOlderHistoryLoadingIndicator,
            isLoadingInitialHistory: isLoadingInitialHistory,
            isPreparingInitialProjection: isPreparingInitialProjection,
            isActiveProjectionPending: isActiveProjectionPending,
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: sendAnimationRequest,
            textAnimationRegistry: presentationSurface.textAnimationRegistry,
            allowsLiveTextAnimation: presentationSurface.textAnimationVisibility.isVisible,
            reduceMotion: reduceMotion,
            markdownRowStyle: markdownRowStyle,
            claimSendAnimation: claimSendAnimation,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop
        )
        if view.isInitialPresentationReady {
            reportInitialPresentationReady()
        }
    }

    @MainActor
    private static func attach(
        _ presentationSurface: TranscriptPresentationSurface,
        to container: SurfaceContainerView
    ) {
        let scrollView = presentationSurface.ensureScrollView()
        guard scrollView.superview !== container else { return }

        // A detached host can receive late layout callbacks while SwiftUI is
        // constructing its replacement. It may adopt an orphaned surface, but
        // must never steal one back from the live container.
        if scrollView.superview?.window != nil,
            container.window == nil,
            container.superview == nil
        {
            return
        }

        (scrollView.superview as? SurfaceContainerView)?
            .relinquishSurface(presentationSurface)
        scrollView.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
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
