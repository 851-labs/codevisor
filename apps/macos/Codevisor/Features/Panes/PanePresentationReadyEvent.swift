import AppKit
import SwiftUI

/// An acknowledgement emitted by pane content after its first authoritative
/// layout. IDs let nested hosts ignore stale acknowledgements from outgoing
/// panes and superseded navigation requests.
struct PanePresentationReadyEvent {
    let paneId: UUID?
    let chatSessionId: UUID?

    static let laidOut = PanePresentationReadyEvent(paneId: nil, chatSessionId: nil)
}

extension EnvironmentValues {
    /// Nested hosts replace this callback and forward it only after their own
    /// handoff commits: row geometry -> pane -> workspace tab -> detail.
    @Entry var panePresentationReady: @MainActor (PanePresentationReadyEvent) -> Void = { _ in }
    /// Identity supplied by the selected pane host to presentation-aware
    /// content such as the transcript virtualizer.
    @Entry var panePresentationIdentity = PanePresentationReadyEvent.laidOut
}

extension View {
    /// Reports readiness after AppKit has attached and laid out this surface.
    /// Transcripts use their stricter virtualizer callback instead.
    func reportsPresentationReadyAfterLayout(_ event: PanePresentationReadyEvent) -> some View {
        overlay {
            PresentationLayoutReadyReader(event: event)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct PresentationLayoutReadyReader: NSViewRepresentable {
    @Environment(\.panePresentationReady) private var reportReady
    let event: PanePresentationReadyEvent

    func makeNSView(context: Context) -> PresentationLayoutReadyView {
        let view = PresentationLayoutReadyView()
        view.onReady = { reportReady(event) }
        return view
    }

    func updateNSView(_ nsView: PresentationLayoutReadyView, context: Context) {
        nsView.onReady = { reportReady(event) }
        nsView.reportIfPossible()
    }
}

private final class PresentationLayoutReadyView: NSView {
    var onReady: (@MainActor () -> Void)?
    private var didReport = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportIfPossible()
    }

    override func layout() {
        super.layout()
        reportIfPossible()
    }

    func reportIfPossible() {
        guard !didReport, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        didReport = true
        // Never mutate SwiftUI state from inside an AppKit layout callback.
        // The next turn is also the first display transaction that can contain
        // this committed geometry.
        DispatchQueue.main.async { [weak self] in
            self?.onReady?()
        }
    }
}
