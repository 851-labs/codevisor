//  The iOS plugin pane's backing state: one PluginPaneModel per pane runs
//  the token→load flow into a cached WebPaneController (mirroring macOS
//  PluginPane), and PluginPaneCache keeps a small LRU of live models so tab
//  switches re-attach without reloading while webviews outside the active
//  canvas are torn down — each WKWebView is a web-content process, which is
//  jetsam-relevant on iOS.

import CodevisorCore
import CodevisorUI
import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit
import os

/// One plugin pane's live state: phase + the cached WebPaneController.
/// Created by PluginPaneCache and torn down when evicted, so the model's
/// lifetime — not the SwiftUI view's — owns the webview.
@MainActor
@Observable
final class PluginPaneModel: Identifiable {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    let id: UUID
    /// Set by the hosting view: `codevisor.setTitle` renames the pane's tab.
    @ObservationIgnored var onTitleChange: ((String) -> Void)?

    private(set) var phase: Phase = .idle

    /// The machine whose plugin-update revisions apply to this pane.
    @ObservationIgnored let serverId: String
    @ObservationIgnored let pluginId: String
    @ObservationIgnored private let paneType: String
    @ObservationIgnored private let workspaceId: UUID?
    @ObservationIgnored private let cwd: String
    @ObservationIgnored private let client: any CodevisorServerClienting
    /// The machine's effective HTTP origin: direct machines answer their
    /// baseURL, relay machines start the loopback bridge on demand
    /// (MachineController.effectiveHTTPBaseURL).
    @ObservationIgnored private let resolveBaseURL: @MainActor () async -> URL?
    @ObservationIgnored private var controller: WebPaneController?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The plugin-update revision the last load ran against; a moved
    /// revision (`plugin.updated`: restart, re-import, re-link) makes the
    /// next `loadIfNeeded` re-run the full token→load flow even on a ready
    /// (or failed) pane.
    @ObservationIgnored private var loadedUpdateRevision: UInt64?

    init(
        paneId: UUID,
        serverId: String,
        pluginId: String,
        paneType: String,
        workspaceId: UUID?,
        cwd: String,
        client: any CodevisorServerClienting,
        resolveBaseURL: @escaping @MainActor () async -> URL?
    ) {
        self.id = paneId
        self.serverId = serverId
        self.pluginId = pluginId
        self.paneType = paneType
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.client = client
        self.resolveBaseURL = resolveBaseURL
    }

    /// The live webView for grid-card snapshots — only once a document has
    /// actually rendered (a loading/failed pane has nothing worth capturing).
    var snapshotWebView: WKWebView? {
        guard phase == .ready else { return nil }
        return controller?.webView
    }

    /// The controller (and its webview), created lazily on first show and
    /// cached until the model is evicted.
    func ensureController(theme: WebPaneThemeTokens) -> WebPaneController {
        if let controller {
            controller.applyTheme(theme)
            return controller
        }
        let controller = WebPaneController(
            context: WebPaneBridgeContext(
                workspaceId: workspaceId?.uuidString.lowercased(),
                cwd: cwd,
                paneId: id.uuidString.lowercased(),
                themeMode: theme.mode
            ),
            theme: theme,
            // Per-plugin persistent storage: HTTP cache and localStorage
            // survive pane teardown/app relaunch, isolated between plugins.
            dataStoreIdentifier: pluginId.isEmpty
                ? nil : WebPaneController.pluginDataStoreIdentifier(for: pluginId)
        )
        controller.onSetTitle = { [weak self] title in self?.onTitleChange?(title) }
        controller.onNavigationFailed = { [weak self] message in
            self?.phase = .failed(message)
        }
        controller.onNavigationFinished = { [weak self] in
            self?.phase = .ready
        }
        self.controller = controller
        return controller
    }

    /// Kicks off the token-then-load flow once, and again whenever the
    /// plugin's update revision moved since the last load (`plugin.updated`:
    /// the plugin's code changed, so a ready pane reloads and a failed pane
    /// retries). Manual Retry goes through `retry()`.
    func loadIfNeeded(theme: WebPaneThemeTokens, updateRevision: UInt64) {
        guard phase == .idle || loadedUpdateRevision != updateRevision else { return }
        load(theme: theme, updateRevision: updateRevision)
    }

    func retry(theme: WebPaneThemeTokens, updateRevision: UInt64) {
        load(theme: theme, updateRevision: updateRevision)
    }

    func applyTheme(_ theme: WebPaneThemeTokens) {
        controller?.applyTheme(theme)
    }

    private func load(theme: WebPaneThemeTokens, updateRevision: UInt64) {
        loadedUpdateRevision = updateRevision
        guard !pluginId.isEmpty, !paneType.isEmpty else {
            phase = .failed("This pane's plugin information is missing.")
            return
        }
        let controller = ensureController(theme: theme)
        phase = .loading
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.client.issuePluginPaneToken(
                    pluginId: self.pluginId,
                    paneId: self.id.uuidString.lowercased(),
                    paneType: self.paneType,
                    workspaceId: self.workspaceId?.uuidString.lowercased(),
                    cwd: self.cwd,
                    themeMode: theme.mode
                )
                guard !Task.isCancelled else { return }
                // Resolved per load so a Retry after a relay reconnect picks
                // up the fresh loopback origin.
                guard let base = await self.resolveBaseURL() else {
                    guard !Task.isCancelled else { return }
                    self.phase = .failed(
                        "This machine's relay connection isn't available yet. Try again once it reconnects."
                    )
                    return
                }
                guard !Task.isCancelled else { return }
                guard let url = Self.paneURL(base: base, path: response.path) else {
                    self.phase = .failed("The server returned an unusable pane address.")
                    return
                }
                controller.load(url)
            } catch {
                guard !Task.isCancelled, !isTaskCancellation(error) else { return }
                Log.plugins.error(
                    "plugin pane token failed for \(self.pluginId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                self.phase = .failed(serverErrorMessage(error))
            }
        }
    }

    /// The machine base URL + the server-relative pane path (which already
    /// carries its own query string).
    private static func paneURL(base: URL, path: String) -> URL? {
        let origin = base.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(origin)\(path)")
    }

    /// Drops the webview and its web-content process. The next visit
    /// reloads from scratch (plugin panes keep durable state server-side).
    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        controller?.stopLoading()
        controller = nil
        phase = .idle
    }
}

/// The app-wide store of live plugin pane models, keyed by pane id. Hidden
/// panes keep their webviews alive for a retention window (Safari-tab style)
/// so tab switches within it are instant, bounded by a hard cap so webviews
/// never stack unboundedly; memory warnings and pane closes tear webviews
/// down eagerly.
@MainActor
final class PluginPaneCache {
    static let shared = PluginPaneCache()

    /// How long a hidden pane's webview stays alive after it was last
    /// visible, balancing instant tab switches against WebKit memory use.
    private let retentionSeconds: TimeInterval = 300
    /// Hard ceiling on simultaneously live webviews regardless of retention —
    /// each one is a web-content process, which is jetsam-relevant on iOS.
    private let capacity = 4

    private var models: [UUID: PluginPaneModel] = [:]
    /// Most recently used last.
    private var usageOrder: [UUID] = []
    /// Last time each pane was used (visible); drives retention expiry.
    private var lastUsed: [UUID: Date] = [:]
    private var sweepTask: Task<Void, Never>?
    private var memoryWarningObserver: (any NSObjectProtocol)?

    init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PluginPaneCache.shared.handleMemoryWarning()
            }
        }
    }

    /// The pane's live model, created via `make` on first use. Marks the
    /// pane as most recently used and evicts webviews beyond the cap.
    func model(for paneId: UUID, make: () -> PluginPaneModel) -> PluginPaneModel {
        let model =
            models[paneId]
            ?? {
                let created = make()
                models[paneId] = created
                return created
            }()
        noteUsed(paneId)
        return model
    }

    /// The pane closed (or left the workspace): tear its webview down now.
    func remove(paneId: UUID) {
        usageOrder.removeAll { $0 == paneId }
        lastUsed.removeValue(forKey: paneId)
        models.removeValue(forKey: paneId)?.teardown()
    }

    /// A ready pane's real pixels for its grid card, via WKWebView's own
    /// snapshotter (ImageRenderer and layer rendering can't see web content).
    func capturePreview(paneId: UUID, completion: @escaping @MainActor (UIImage) -> Void) {
        guard let webView = models[paneId]?.snapshotWebView, webView.bounds.width > 0 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { image, _ in
            guard let image else { return }
            MainActor.assumeIsolated {
                completion(image)
            }
        }
    }

    private func noteUsed(_ paneId: UUID) {
        usageOrder.removeAll { $0 == paneId }
        usageOrder.append(paneId)
        lastUsed[paneId] = Date()
        while usageOrder.count > capacity {
            evictOldest()
        }
        scheduleSweep()
    }

    /// Keep only the most recently used (visible) pane's webview.
    private func handleMemoryWarning() {
        while usageOrder.count > 1 {
            evictOldest()
        }
    }

    private func evictOldest() {
        guard !usageOrder.isEmpty else { return }
        let evicted = usageOrder.removeFirst()
        lastUsed.removeValue(forKey: evicted)
        models.removeValue(forKey: evicted)?.teardown()
    }

    /// Tears down hidden panes whose retention window has expired. One sweep
    /// task runs while any hidden pane is alive, sleeping until the earliest
    /// expiry; the visible (most recently used) pane is never expired.
    private func scheduleSweep() {
        guard sweepTask == nil, usageOrder.count > 1 else { return }
        sweepTask = Task { @MainActor [weak self] in
            defer { self?.sweepTask = nil }
            while let cache = self, cache.usageOrder.count > 1 {
                let now = Date()
                let expiries = cache.usageOrder.dropLast()
                    .compactMap { cache.lastUsed[$0] }
                    .map { $0.addingTimeInterval(cache.retentionSeconds) }
                guard let next = expiries.min() else { return }
                let wait = next.timeIntervalSince(now)
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    if Task.isCancelled { return }
                }
                self?.evictExpired()
            }
        }
    }

    private func evictExpired() {
        let cutoff = Date().addingTimeInterval(-retentionSeconds)
        for paneId in usageOrder.dropLast()
        where (lastUsed[paneId] ?? .distantPast) <= cutoff {
            usageOrder.removeAll { $0 == paneId }
            lastUsed.removeValue(forKey: paneId)
            models.removeValue(forKey: paneId)?.teardown()
        }
    }
}
