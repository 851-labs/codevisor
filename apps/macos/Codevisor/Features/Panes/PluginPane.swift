//  The plugin pane: hosts one plugin-contributed webview through the server's
//  plugin proxy. On first view it exchanges an authorized pane-token request
//  for the pane URL, then loads it in a cached WebPaneController (so its web
//  content — like the terminal's surface — survives tab switches). Token or
//  navigation failures render a native error card with Retry, never a blank
//  webview.

import Foundation
import Observation
import SwiftUI
import CodevisorCore
import CodevisorUI
import os

@MainActor
@Observable
final class PluginPane: Pane, Identifiable {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    let id: UUID
    let kind: PaneKind = .plugin

    @ObservationIgnored var onGroupCommand: ((PaneGroupCommand) -> Void)?
    @ObservationIgnored var onFocusChanged: ((Bool) -> Void)?
    /// Set by the pane group: `codevisor.setTitle` renames this pane's tab.
    @ObservationIgnored var onTitleChange: ((String) -> Void)?

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let context: PaneContext
    @ObservationIgnored let pluginId: String
    @ObservationIgnored private let paneType: String
    @ObservationIgnored private var controller: WebPaneController?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The plugin-update revision the last load ran against; a moved
    /// revision (`plugin.updated`: restart, re-import, re-link) makes the
    /// next `loadIfNeeded` re-run the full token→load flow even on a ready
    /// (or failed) pane.
    @ObservationIgnored private var loadedUpdateRevision: UInt64?

    /// The machine whose plugin-update revisions apply to this pane.
    var serverId: String { context.machine.id }

    init(context: PaneContext, descriptor: PaneDescriptorState) {
        self.id = context.paneId
        self.context = context
        self.pluginId = descriptor.pluginId ?? ""
        self.paneType = descriptor.pluginPaneType ?? ""
    }

    /// The workspace's one working directory (the anchor session's cwd, else
    /// the project folder) — same resolution the terminal pane uses.
    private var workingDirectory: String {
        context.session.cwd ?? context.project.folderURL.path
    }

    private var client: any CodevisorServerClienting {
        context.client ?? CodevisorServerClient(config: context.machine.serverConfig)
    }

    /// The controller (and its webview), created lazily on first show and
    /// cached for the pane's lifetime.
    func ensureController(theme: WebPaneThemeTokens) -> WebPaneController {
        if let controller {
            controller.applyTheme(theme)
            return controller
        }
        let controller = WebPaneController(
            context: WebPaneBridgeContext(
                workspaceId: context.workspaceId?.uuidString.lowercased(),
                cwd: workingDirectory,
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
                    workspaceId: self.context.workspaceId?.uuidString.lowercased(),
                    cwd: self.workingDirectory,
                    themeMode: theme.mode
                )
                guard !Task.isCancelled else { return }
                // The machine's effective HTTP origin: direct machines answer
                // immediately; cloud machines wait for the relay loopback
                // bridge to come up. Resolved per load, so a Retry after a
                // relay reconnect picks up the fresh origin.
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

    /// The machine's effective HTTP origin, via the context's resolver
    /// (which starts the relay loopback bridge on demand for cloud
    /// machines). Preview/legacy contexts fall back to the configured
    /// baseURL.
    private func resolveBaseURL() async -> URL? {
        guard let resolveHTTPBaseURL = context.resolveHTTPBaseURL else {
            return context.machine.baseURL
        }
        return await resolveHTTPBaseURL()
    }

    /// The machine base URL + the server-relative pane path (which already
    /// carries its own query string).
    private static func paneURL(base: URL, path: String) -> URL? {
        let origin = base.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(origin)\(path)")
    }

    // MARK: - Pane hooks

    func makeView() -> AnyView {
        AnyView(PluginPaneView(pane: self))
    }

    func focus() {
        guard let controller else { return }
        controller.webView.window?.makeFirstResponder(controller.webView)
    }

    func visibilityChanged(_ visible: Bool) {}

    /// Closing the tab needs no server-side teardown here: the shared pane
    /// record is closed by the group's sync flow, and the plugin server's
    /// idle timer reaps the process once no panes are connected.
    func willDelete() async {
        detach()
    }

    func detach() {
        loadTask?.cancel()
        loadTask = nil
        controller?.stopLoading()
        controller = nil
        phase = .idle
    }
}

/// The plugin pane's content: the webview once loading, with a native error
/// card (Retry) for token or navigation failures — never a blank webview.
struct PluginPaneView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var pane: PluginPane

    private var themeTokens: WebPaneThemeTokens {
        WebPaneThemeTokens(palette: theme.palette, isDark: colorScheme == .dark)
    }

    /// The plugin's reload token: `plugin.updated` (restart, re-import,
    /// re-link) bumps it, and the pane re-runs its full token→load flow —
    /// a fresh pane token and URL, not a bare webView.reload(), so relay
    /// origins re-resolve too.
    private var updateRevision: UInt64 {
        environment.pluginUpdateRevision(forServer: pane.serverId, pluginId: pane.pluginId)
    }

    var body: some View {
        let tokens = themeTokens
        let revision = updateRevision
        ZStack {
            if case let .failed(message) = pane.phase {
                errorCard(message: message, tokens: tokens, revision: revision)
            } else {
                WebPaneView(controller: pane.ensureController(theme: tokens))
                if pane.phase == .loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.paneBackground)
        .task(id: pane.id) {
            pane.loadIfNeeded(theme: tokens, updateRevision: revision)
        }
        .onChange(of: revision) { _, moved in
            // Failed panes retry through the same path automatically.
            pane.loadIfNeeded(theme: tokens, updateRevision: moved)
        }
        .onChange(of: tokens) { _, updated in
            pane.applyTheme(updated)
        }
    }

    private func errorCard(
        message: String,
        tokens: WebPaneThemeTokens,
        revision: UInt64
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(theme.textSecondary)
            Text("Couldn't load this plugin pane")
                .font(.body.weight(.medium))
                .foregroundStyle(theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Retry") {
                pane.retry(theme: tokens, updateRevision: revision)
            }
        }
        .padding(24)
    }
}
