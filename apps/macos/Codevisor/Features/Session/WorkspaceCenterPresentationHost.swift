import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceCenterSurface: Equatable {
    let id: UUID
    var node: SplitNode
    var activeLeafId: UUID?
}

/// Keeps a selected workspace tab's last good pixels mounted while the next
/// tab's split tree prepares underneath. The pending tree stays in the same
/// ForEach identity when promoted, so a ready transcript is never rebuilt at
/// the handoff boundary.
struct WorkspaceCenterPresentationHost<Content: View>: View {
    let surface: WorkspaceCenterSurface
    let requiredPaneIds: (WorkspaceCenterSurface) -> Set<UUID>
    @ViewBuilder let content: (WorkspaceCenterSurface) -> Content

    @Environment(\.theme) private var theme
    @Environment(\.panePresentationReady) private var parentPresentationReady
    @State private var presentation: StagedPresentationGate<UUID>
    @State private var retainedSurfaces: [UUID: WorkspaceCenterSurface]
    @State private var pendingRequiredPaneIds: Set<UUID> = []
    @State private var pendingReadyEvents: [UUID: PanePresentationReadyEvent] = [:]

    init(
        surface: WorkspaceCenterSurface,
        requiredPaneIds: @escaping (WorkspaceCenterSurface) -> Set<UUID>,
        @ViewBuilder content: @escaping (WorkspaceCenterSurface) -> Content
    ) {
        self.surface = surface
        self.requiredPaneIds = requiredPaneIds
        self.content = content
        var initial = StagedPresentationGate<UUID>()
        let generation = initial.request(surface.id)
        _ = initial.commit(surface.id, generation: generation)
        _presentation = State(initialValue: initial)
        _retainedSurfaces = State(initialValue: [surface.id: surface])
    }

    var body: some View {
        ZStack {
            ForEach(visibleSurfaceIds, id: \.self) { id in
                let isPresented = id == presentation.presentedRoute
                let generation =
                    id == presentation.requestedRoute
                    ? presentation.generation
                    : nil
                if let retained = resolvedSurface(id) {
                    content(retained)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.windowBackground)
                        .reportsPresentationReadyAfterLayout(.laidOut)
                        .environment(\.panePresentationReady) { event in
                            surfaceDidBecomeReady(
                                event,
                                surfaceId: id,
                                generation: generation
                            )
                        }
                        .zIndex(isPresented ? 1 : 0)
                        .allowsHitTesting(isPresented)
                        .accessibilityHidden(!isPresented)
                }
            }
        }
        .onChange(of: surface, initial: true) { _, newSurface in
            requestPresentation(of: newSurface)
        }
    }

    private var visibleSurfaceIds: [UUID] {
        guard let presented = presentation.presentedRoute else { return [surface.id] }
        guard let requested = presentation.requestedRoute, requested != presented else {
            return [presented]
        }
        return [requested, presented]
    }

    private func resolvedSurface(_ id: UUID) -> WorkspaceCenterSurface? {
        id == surface.id ? surface : retainedSurfaces[id]
    }

    private func requestPresentation(of newSurface: WorkspaceCenterSurface) {
        retainedSurfaces[newSurface.id] = newSurface
        guard presentation.presentedRoute != newSurface.id else {
            if presentation.requestedRoute != newSurface.id {
                let generation = presentation.request(newSurface.id)
                _ = presentation.commit(newSurface.id, generation: generation)
            }
            pendingRequiredPaneIds = []
            pendingReadyEvents = [:]
            pruneRetainedSurfaces()
            return
        }
        _ = presentation.request(newSurface.id)
        pendingRequiredPaneIds = requiredPaneIds(newSurface)
        pendingReadyEvents = [:]
    }

    private func surfaceDidBecomeReady(
        _ event: PanePresentationReadyEvent,
        surfaceId: UUID,
        generation: UInt64?
    ) {
        guard let requested = presentation.requestedRoute,
            requested != presentation.presentedRoute
        else {
            parentPresentationReady(event)
            return
        }
        guard surfaceId == requested,
            generation == presentation.generation
        else { return }

        if pendingRequiredPaneIds.isEmpty {
            guard event.paneId == nil else { return }
        } else {
            guard let paneId = event.paneId,
                pendingRequiredPaneIds.contains(paneId)
            else { return }
            pendingReadyEvents[paneId] = event
            guard pendingRequiredPaneIds.isSubset(of: Set(pendingReadyEvents.keys)) else {
                return
            }
        }

        let readyEvents = Array(pendingReadyEvents.values)
        guard presentation.commit(requested, generation: presentation.generation) else { return }
        pendingRequiredPaneIds = []
        pendingReadyEvents = [:]
        pruneRetainedSurfaces()
        if readyEvents.isEmpty {
            parentPresentationReady(event)
        } else {
            // A root detail handoff may be waiting for one particular routed
            // chat. Forward every ready leaf only after the whole split is
            // stable so it can select the matching session acknowledgement.
            for readyEvent in readyEvents {
                parentPresentationReady(readyEvent)
            }
        }
    }

    private func pruneRetainedSurfaces() {
        let retainedIds = Set(visibleSurfaceIds)
        retainedSurfaces = retainedSurfaces.filter { retainedIds.contains($0.key) }
    }
}
