//  Drag-to-rearrange for one workspace tab's split leaves. Each mounted
//  leaf reports its global frame; while a header drag is active the nearest
//  valid edge of the hovered leaf becomes the drop target.

import AppKit
import SwiftUI
import CodevisorCore

struct WorkspaceSplitDropResolution: Equatable {
    let targetLeafId: UUID
    let edge: SplitEdge
}

@MainActor
@Observable
final class WorkspaceSplitDragCoordinator {
    struct ActiveDrag {
        let sourceLeafId: UUID
        let name: String
        let kind: PaneKind
        let isAgentOwned: Bool
        var location: CGPoint
        var resolution: WorkspaceSplitDropResolution?
    }

    static let minChildWidth: CGFloat = 320
    static let minChildHeight: CGFloat = 280

    private struct OwnedFrame {
        let owner: UUID
        var frame: CGRect
    }

    private(set) var active: ActiveDrag?
    @ObservationIgnored private var leafFrames: [UUID: OwnedFrame] = [:]
    /// Container-owned validation against the candidate tree after the
    /// source leaf has been removed and reinserted.
    @ObservationIgnored var canResolve: ((UUID, WorkspaceSplitDropResolution, CGSize) -> Bool)?
    @ObservationIgnored var onResolve: ((UUID, WorkspaceSplitDropResolution) -> Void)?

    func registerLeaf(owner: UUID, leafId: UUID) {
        if leafFrames[leafId]?.owner != owner {
            leafFrames[leafId] = OwnedFrame(owner: owner, frame: .zero)
        }
    }

    func updateLeafFrame(_ frame: CGRect, owner: UUID, leafId: UUID) {
        guard leafFrames[leafId]?.owner == owner else { return }
        leafFrames[leafId]?.frame = frame
        refreshResolution()
    }

    func unregisterLeaf(owner: UUID, leafId: UUID) {
        guard leafFrames[leafId]?.owner == owner else { return }
        leafFrames[leafId] = nil
        refreshResolution()
    }

    func dragUpdated(
        sourceLeafId: UUID,
        name: String,
        kind: PaneKind,
        isAgentOwned: Bool,
        location: CGPoint
    ) {
        active = ActiveDrag(
            sourceLeafId: sourceLeafId,
            name: name,
            kind: kind,
            isAgentOwned: isAgentOwned,
            location: location,
            resolution: resolve(location, sourceLeafId: sourceLeafId)
        )
    }

    @discardableResult
    func dragEnded() -> Bool {
        defer { active = nil }
        guard let active, let resolution = active.resolution else { return false }
        onResolve?(active.sourceLeafId, resolution)
        return true
    }

    func dragCancelled() {
        active = nil
    }

    func previewEdge(for leafId: UUID) -> SplitEdge? {
        guard let resolution = active?.resolution,
              resolution.targetLeafId == leafId else { return nil }
        return resolution.edge
    }

    private func refreshResolution() {
        guard var active else { return }
        active.resolution = resolve(active.location, sourceLeafId: active.sourceLeafId)
        self.active = active
    }

    private func resolve(_ location: CGPoint, sourceLeafId: UUID) -> WorkspaceSplitDropResolution? {
        let target = leafFrames
            .filter { leafId, registration in
                leafId != sourceLeafId
                    && registration.frame.width > 0
                    && registration.frame.height > 0
                    && registration.frame.contains(location)
            }
            // Frames should not overlap, but choosing the smallest makes a
            // stale ancestor-sized registration harmless during remounts.
            .min { lhs, rhs in
                lhs.value.frame.width * lhs.value.frame.height
                    < rhs.value.frame.width * rhs.value.frame.height
            }

        guard let (leafId, registration) = target else { return nil }
        let canvas = leafFrames.values
            .map(\.frame)
            .filter { $0.width > 0 && $0.height > 0 }
            .reduce(CGRect.null) { $0.union($1) }

        for edge in candidateEdges(in: registration.frame, location: location) {
            let resolution = WorkspaceSplitDropResolution(targetLeafId: leafId, edge: edge)
            if let canResolve {
                if canResolve(sourceLeafId, resolution, canvas.size) { return resolution }
            } else if targetCanSplit(registration.frame, on: edge) {
                return resolution
            }
        }
        return nil
    }

    private func candidateEdges(in frame: CGRect, location: CGPoint) -> [SplitEdge] {
        let u = Double((location.x - frame.minX) / frame.width)
        let v = Double((location.y - frame.minY) / frame.height)
        let candidates: [(edge: SplitEdge, distance: Double)] = [
            (edge: .leading, distance: u),
            (edge: .trailing, distance: 1 - u),
            (edge: .top, distance: v),
            (edge: .bottom, distance: 1 - v)
        ]
        return candidates
            .sorted { $0.distance < $1.distance }
            .map(\.edge)
    }

    private func targetCanSplit(_ frame: CGRect, on edge: SplitEdge) -> Bool {
        switch edge {
        case .leading, .trailing:
            return (frame.width - 1) / 2 >= Self.minChildWidth
        case .top, .bottom:
            return (frame.height - 1) / 2 >= Self.minChildHeight
        }
    }
}

struct WorkspaceSplitDropZoneModifier: ViewModifier {
    let coordinator: WorkspaceSplitDragCoordinator?
    let leafId: UUID

    @State private var measuredFrame: CGRect = .zero
    @State private var geometryOwner = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                measuredFrame = frame
                coordinator?.updateLeafFrame(frame, owner: geometryOwner, leafId: leafId)
            }
            .onChange(of: coordinator?.active?.sourceLeafId) { _, active in
                guard active != nil, measuredFrame != .zero else { return }
                coordinator?.registerLeaf(owner: geometryOwner, leafId: leafId)
                coordinator?.updateLeafFrame(measuredFrame, owner: geometryOwner, leafId: leafId)
            }
            .onAppear {
                coordinator?.registerLeaf(owner: geometryOwner, leafId: leafId)
                if measuredFrame != .zero {
                    coordinator?.updateLeafFrame(measuredFrame, owner: geometryOwner, leafId: leafId)
                }
            }
            .onDisappear {
                coordinator?.unregisterLeaf(owner: geometryOwner, leafId: leafId)
            }
            .overlay {
                if let edge = coordinator?.previewEdge(for: leafId) {
                    WorkspaceSplitDropPreview(edge: edge)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func workspaceSplitDropZone(
        _ coordinator: WorkspaceSplitDragCoordinator?,
        leafId: UUID
    ) -> some View {
        modifier(WorkspaceSplitDropZoneModifier(coordinator: coordinator, leafId: leafId))
    }
}

private struct WorkspaceSplitDropPreview: View {
    @Environment(\.theme) private var theme
    let edge: SplitEdge

    var body: some View {
        GeometryReader { geometry in
            let rect = regionRect(in: geometry.size)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.accent.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.4))
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .animation(.snappy(duration: 0.16), value: edge)
        }
        .padding(2)
    }

    private func regionRect(in size: CGSize) -> CGRect {
        switch edge {
        case .leading:
            CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .trailing:
            CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:
            CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom:
            CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

struct WorkspaceSplitDragGhost: View {
    @Environment(\.theme) private var theme
    let name: String
    let kind: PaneKind
    let isAgentOwned: Bool

    private var iconName: String {
        switch kind {
        case .chat: "text.bubble"
        case .terminal: isAgentOwned ? "server.rack" : "terminal"
        case .newTab: "square.dashed"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.popoverBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.separator)
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}
