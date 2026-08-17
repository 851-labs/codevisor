import CodevisorCore
import CodevisorUI
import SwiftUI

extension RootView {
    func stagedDetail(_ store: SessionStore) -> some View {
        ZStack {
            ForEach(detailPresentationLayers, id: \.surfaceId) { route in
                let isPresented = route == detailPresentation.presentedRoute
                let generation =
                    route == detailPresentation.requestedRoute
                    ? detailPresentation.generation
                    : nil
                detail(store, selection: route.selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.windowBackground)
                    .environment(\.panePresentationReady) { event in
                        detailDidBecomeReady(
                            event,
                            route: route,
                            generation: generation
                        )
                    }
                    .zIndex(isPresented ? 1 : 0)
                    .allowsHitTesting(isPresented)
                    .accessibilityHidden(!isPresented)
            }
        }
        .onChange(of: desiredDetailPresentationRoute, initial: true) { _, route in
            requestDetailPresentation(route)
        }
    }

    private var desiredDetailPresentationRoute: DetailPresentationRoute {
        DetailPresentationRoute(selection: selection, surfaceId: detailSurfaceId(for: selection))
    }

    private var detailPresentationLayers: [DetailPresentationRoute] {
        guard let presented = detailPresentation.presentedRoute else {
            return [desiredDetailPresentationRoute]
        }
        guard let requested = detailPresentation.requestedRoute,
            requested.surfaceId != presented.surfaceId
        else { return [presented] }
        // Incoming destination first (underneath), last-good destination above.
        return [requested, presented]
    }

    private func requestDetailPresentation(_ route: DetailPresentationRoute) {
        let generation = detailPresentation.request(route)
        guard let presented = detailPresentation.presentedRoute,
            presented.surfaceId != route.surfaceId
        else {
            // Sibling chats share one mounted workspace. Update that route in
            // place and let its workspace-tab host perform the visual handoff.
            _ = detailPresentation.commit(route, generation: generation)
            return
        }
    }

    private func detailDidBecomeReady(
        _ event: PanePresentationReadyEvent,
        route: DetailPresentationRoute,
        generation: UInt64?
    ) {
        guard route == detailPresentation.requestedRoute,
            route.surfaceId != detailPresentation.presentedRoute?.surfaceId,
            generation == detailPresentation.generation
        else { return }

        switch route.surfaceId {
        case .workspace:
            guard case let .session(_, sessionId) = route.selection else { return }
            guard event.chatSessionId == sessionId else { return }
        case .bootstrap, .blocked, .newChat:
            guard event.paneId == nil, event.chatSessionId == nil else { return }
        }
        _ = detailPresentation.commit(route, generation: detailPresentation.generation)
    }

    private func detailSurfaceId(for selection: SidebarSelection?) -> DetailSurfaceId {
        let machineId = environment.machines.selectedMachineId
        if blocksSelectedServerContent {
            return .blocked(machineId)
        }
        guard case let .session(serverId, sessionId) = selection,
            serverId == machineId,
            let session = environment.projectList.sessions.first(where: {
                $0.serverId == serverId && $0.id == sessionId
            }),
            environment.projectList.projects.contains(where: {
                $0.serverId == serverId && $0.id == session.projectId
            })
        else {
            return .newChat(machineId)
        }
        return .workspace(
            serverId: serverId,
            workspaceId: environment.workspaces.workspaceId(forSession: sessionId) ?? sessionId
        )
    }
}
