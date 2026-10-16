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
  @ObservationIgnored var onTitleChange: ((String) -> Void)?

  private(set) var phase: Phase = .idle

  @ObservationIgnored private let context: PaneContext
  @ObservationIgnored let pluginId: String
  @ObservationIgnored private let paneType: String
  @ObservationIgnored private var controller: WebPaneController?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var loadedUpdateRevision: UInt64?

  var serverId: String { context.machine.id }

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    self.id = context.paneId
    self.context = context
    self.pluginId = descriptor.pluginId ?? ""
    self.paneType = descriptor.pluginPaneType ?? ""
  }

  private var workingDirectory: String {
    PaneWorkingDirectory.resolve(
      anchor: context.session.map { .session(cwd: $0.cwd) } ?? .workspace,
      workspaceRootDirectory: context.workspaceRootDirectory,
      projectFolderPath: context.project.folderURL.path)
  }

  private var client: any CodevisorServerClienting {
    context.client ?? CodevisorServerClient(config: context.machine.serverConfig)
  }

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

  private func resolveBaseURL() async -> URL? {
    guard let resolveHTTPBaseURL = context.resolveHTTPBaseURL else {
      return context.machine.baseURL
    }
    return await resolveHTTPBaseURL()
  }

  private static func paneURL(base: URL, path: String) -> URL? {
    let origin = base.absoluteString
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return URL(string: "\(origin)\(path)")
  }

  func makeView() -> AnyView {
    AnyView(PluginPaneView(pane: self))
  }

  func focus() {
    guard let controller else { return }
    controller.webView.window?.makeFirstResponder(controller.webView)
  }

  func visibilityChanged(_ visible: Bool) {}

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

struct PluginPaneView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.colorScheme) private var colorScheme
  var pane: PluginPane

  private var themeTokens: WebPaneThemeTokens {
    WebPaneThemeTokens(isDark: colorScheme == .dark)
  }

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
    .task(id: pane.id) {
      pane.loadIfNeeded(theme: tokens, updateRevision: revision)
    }
    .onChange(of: revision) { _, moved in
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
        .foregroundStyle(.secondary)
      Text("Couldn't load this plugin pane")
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      Button("Retry") {
        pane.retry(theme: tokens, updateRevision: revision)
      }
    }
    .padding(24)
  }
}
