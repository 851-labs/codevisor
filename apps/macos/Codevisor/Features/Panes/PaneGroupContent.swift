import CodevisorCore
import CodevisorUI
import SwiftUI

/// The selected pane's content. During a selection change the outgoing pane
/// remains the visible surface while the incoming pane mounts underneath it.
/// The incoming pane becomes authoritative only after it reports committed
/// layout (for chats, that means measured virtual rows + restored viewport).
struct PaneGroupContent: View {
    var group: PaneGroupModel
    @Environment(\.theme) private var theme
    @Environment(\.panePresentationReady) private var parentPresentationReady
    @State private var presentation: StagedPresentationGate<PaneRoute>

    private enum PaneRoute: Hashable {
        case pane(UUID)
        case empty
    }

    init(group: PaneGroupModel) {
        self.group = group
        let initialRoute = Self.route(for: group.state.selectedPaneId)
        var initial = StagedPresentationGate<PaneRoute>()
        let generation = initial.request(initialRoute)
        _ = initial.commit(initialRoute, generation: generation)
        _presentation = State(initialValue: initial)
    }

    var body: some View {
        ZStack {
            ForEach(visibleRoutes, id: \.self) { route in
                let generation =
                    route == presentation.requestedRoute
                    ? presentation.generation
                    : nil
                paneLayer(route, generation: generation)
                    .zIndex(route == presentation.presentedRoute ? 1 : 0)
                    .allowsHitTesting(route == presentation.presentedRoute)
                    .accessibilityHidden(route != presentation.presentedRoute)
            }
        }
        .onChange(of: selectedRoute, initial: true) { _, route in
            requestPresentation(of: route)
        }
    }

    private var selectedRoute: PaneRoute {
        Self.route(for: group.state.selectedPaneId)
    }

    private var visibleRoutes: [PaneRoute] {
        guard let presented = presentation.presentedRoute else { return [selectedRoute] }
        guard let requested = presentation.requestedRoute, requested != presented else {
            return [presented]
        }
        // Incoming first (underneath), outgoing second (above).
        return [requested, presented]
    }

    @ViewBuilder
    private func paneLayer(_ route: PaneRoute, generation: UInt64?) -> some View {
        switch route {
        case .empty:
            Color.clear
                .reportsPresentationReadyAfterLayout(.laidOut)
        case let .pane(id):
            if let descriptor = group.state.panes.first(where: { $0.id == id }) {
                let pane = group.pane(for: descriptor)
                let event = PanePresentationReadyEvent(
                    paneId: descriptor.id,
                    chatSessionId: descriptor.chatSessionId
                )
                pane.makeView()
                    .id(pane.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.windowBackground)
                    // Terminal, New Tab, and future non-chat panes are ready
                    // after their native/SwiftUI surface has laid out. Chat
                    // panes use the stricter virtualizer acknowledgement.
                    .modifier(
                        ImmediatePaneReadinessModifier(
                            isEnabled: descriptor.kind != .chat,
                            event: event
                        )
                    )
                    // Keep this outside the modifier so both pane content and
                    // its AppKit layout reader report to this handoff host.
                    .environment(\.panePresentationReady) { event in
                        presentationDidBecomeReady(event, generation: generation)
                    }
                    .environment(\.panePresentationIdentity, event)
            }
        }
    }

    private func requestPresentation(of route: PaneRoute) {
        guard presentation.presentedRoute != route else {
            // Returning to the still-visible pane cancels any preparation that
            // rapid tab switching left underneath it.
            if presentation.requestedRoute != route {
                let generation = presentation.request(route)
                _ = presentation.commit(route, generation: generation)
            }
            return
        }
        let generation = presentation.request(route)
        guard case let .pane(presentedId) = presentation.presentedRoute,
            group.state.panes.contains(where: { $0.id == presentedId }),
            route != .empty
        else {
            // A closed pane has no pixels worth retaining; empty destinations
            // likewise have no asynchronous content to prepare.
            _ = presentation.commit(route, generation: generation)
            return
        }
    }

    private func presentationDidBecomeReady(
        _ event: PanePresentationReadyEvent,
        generation: UInt64?
    ) {
        guard let requested = presentation.requestedRoute,
            requested != presentation.presentedRoute
        else {
            parentPresentationReady(event)
            return
        }
        guard case let .pane(requestedId) = requested,
            event.paneId == requestedId,
            generation == presentation.generation
        else { return }
        let generation = presentation.generation
        guard presentation.commit(requested, generation: generation) else { return }
        parentPresentationReady(event)
    }

    private static func route(for paneId: UUID?) -> PaneRoute {
        paneId.map(PaneRoute.pane) ?? .empty
    }
}

private struct ImmediatePaneReadinessModifier: ViewModifier {
    let isEnabled: Bool
    let event: PanePresentationReadyEvent

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.reportsPresentationReadyAfterLayout(event)
        } else {
            content
        }
    }
}
