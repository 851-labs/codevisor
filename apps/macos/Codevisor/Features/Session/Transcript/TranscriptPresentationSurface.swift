import AppKit
import CodevisorCore
import StreamMarkdown

/// One retained native transcript presentation. Unlike `SessionScrollState`,
/// this keeps the mounted AppKit/SwiftUI row window alive so revisiting a chat
/// can reattach an already-laid-out surface on its first frame.
@MainActor
final class TranscriptPresentationSurface {
    let textAnimationVisibility = StreamingTextAnimationVisibility(initiallyVisible: false)
    let textAnimationRegistry = StreamingTextAnimationRegistry()

    private weak var controller: SessionController?
    private var retainedScrollView: VirtualizedTranscriptScrollView?
    private var visibilityOwners: Set<UUID> = []
    private(set) var composerHeight: CGFloat = 96
    private(set) var composerMaskSize: CGSize = .zero
    var isQueueExpanded = true

    init(controller: SessionController) {
        self.controller = controller
    }

    var existingScrollView: VirtualizedTranscriptScrollView? { retainedScrollView }
    var isWarm: Bool { retainedScrollView?.isInitialPresentationReady == true }
    var isAttachedToWindow: Bool { retainedScrollView?.window != nil }

    /// Native transcript construction is intentionally lazy. Looking up a
    /// cached surface happens while SwiftUI is committing sidebar selection,
    /// so that lookup must never instantiate the AppKit hierarchy.
    func ensureScrollView() -> VirtualizedTranscriptScrollView {
        if let retainedScrollView { return retainedScrollView }
        let scrollView = VirtualizedTranscriptScrollView()
        retainedScrollView = scrollView
        return scrollView
    }

    func matches(controller: SessionController) -> Bool {
        self.controller === controller
    }

    /// Appearance callbacks from outgoing and incoming SwiftUI trees can
    /// overlap. Reference-count them so a late disappear cannot pause the
    /// newly reattached surface's streaming-text presentation.
    func appear(owner: UUID) {
        let wasHidden = visibilityOwners.isEmpty
        visibilityOwners.insert(owner)
        if wasHidden {
            textAnimationRegistry.prepareForPresentation()
            textAnimationVisibility.appear()
        }
    }

    func disappear(owner: UUID) {
        visibilityOwners.remove(owner)
        if visibilityOwners.isEmpty {
            textAnimationVisibility.disappear()
        }
    }

    func updateComposerHeight(_ height: CGFloat) {
        composerHeight = height
    }

    func updateComposerMaskSize(_ size: CGSize) {
        composerMaskSize = size
    }

    func prepareForEviction() {
        guard let scrollView = retainedScrollView, scrollView.window == nil else { return }
        retainedScrollView = nil
        scrollView.prepareForDismantle()
        scrollView.removeFromSuperview()
        visibilityOwners.removeAll()
        textAnimationVisibility.disappear()
    }
}

/// A small LRU of detached transcript presentations. Window-attached surfaces
/// are never evicted, so split chats remain independent even when their count
/// exceeds the warm-cache budget.
@MainActor
final class TranscriptPresentationSurfaceCache {
    struct Key: Hashable {
        let serverID: String
        let sessionID: UUID
        let paneID: UUID
    }

    private struct Entry {
        let surface: TranscriptPresentationSurface
    }

    private let maxDetachedSurfaceCount: Int
    private var entries: [Key: Entry] = [:]
    private var accessOrder: [Key] = []
    private var trimTask: Task<Void, Never>?

    init(maxDetachedSurfaceCount: Int = 6) {
        self.maxDetachedSurfaceCount = max(1, maxDetachedSurfaceCount)
    }

    func surface(
        for key: Key,
        controller: SessionController
    ) -> TranscriptPresentationSurface {
        if let entry = entries[key], entry.surface.matches(controller: controller) {
            touch(key)
            scheduleTrim(excluding: key)
            return entry.surface
        }

        remove(key)
        let surface = TranscriptPresentationSurface(controller: controller)
        entries[key] = Entry(surface: surface)
        touch(key)
        scheduleTrim(excluding: key)
        return surface
    }

    func remove(serverID: String, sessionID: UUID) {
        let keys = entries.keys.filter {
            $0.serverID == serverID && $0.sessionID == sessionID
        }
        for key in keys {
            remove(key)
        }
    }

    private func touch(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    /// Cache maintenance is lower priority than navigation. Waiting until the
    /// next frame keeps native teardown and deallocation out of the selection
    /// transaction even when a workspace change crosses the LRU boundary.
    private func scheduleTrim(excluding protectedKey: Key) {
        trimTask?.cancel()
        trimTask = Task { @MainActor [weak self] in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            trimTask = nil
            trimDetachedSurfaces(excluding: protectedKey)
        }
    }

    private func trimDetachedSurfaces(excluding protectedKey: Key) {
        let detached = accessOrder.filter { key in
            key != protectedKey
                && entries[key]?.surface.isAttachedToWindow == false
        }
        guard detached.count > maxDetachedSurfaceCount else { return }
        for key in detached.dropLast(maxDetachedSurfaceCount) {
            remove(key)
        }
    }

    private func remove(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        guard let entry = entries.removeValue(forKey: key) else { return }
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            entry.surface.prepareForEviction()
        }
    }
}
