import CodevisorCore
import CodevisorUI
import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit
import os

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
  @ObservationIgnored var onTitleChange: ((String) -> Void)?

  private(set) var phase: Phase = .idle

  @ObservationIgnored let serverId: String
  @ObservationIgnored let pluginId: String
  @ObservationIgnored private let paneType: String
  @ObservationIgnored private let workspaceId: UUID?
  @ObservationIgnored private let cwd: String
  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let access: PluginAccessController
  @ObservationIgnored private let resolveBaseURL: @MainActor () async -> URL?
  @ObservationIgnored private let recoverConnection: @MainActor () async -> URL?
  @ObservationIgnored private var loadedBaseURL: URL?
  @ObservationIgnored private var lastTheme: WebPaneThemeTokens?
  @ObservationIgnored private var connectionFailure = false
  @ObservationIgnored private var connectionRecovery = WebConnectionRecovery()
  @ObservationIgnored private var controller: WebPaneController?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var loadedUpdateRevision: UInt64?

  init(
    paneId: UUID,
    serverId: String,
    pluginId: String,
    paneType: String,
    workspaceId: UUID?,
    cwd: String,
    client: any CodevisorServerClienting,
    access: PluginAccessController,
    resolveBaseURL: @escaping @MainActor () async -> URL?,
    recoverConnection: @escaping @MainActor () async -> URL?
  ) {
    self.id = paneId
    self.serverId = serverId
    self.pluginId = pluginId
    self.paneType = paneType
    self.workspaceId = workspaceId
    self.cwd = cwd
    self.client = client
    self.access = access
    self.resolveBaseURL = resolveBaseURL
    self.recoverConnection = recoverConnection
  }

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
      dataStoreIdentifier: pluginId.isEmpty
        ? nil : WebPaneController.pluginDataStoreIdentifier(for: pluginId)
    )
    controller.onSetTitle = { [weak self] title in self?.onTitleChange?(title) }
    controller.onNavigationFailed = { [weak self] message in
      self?.phase = .failed(message)
    }
    controller.onConnectionFailure = { [weak self] _ in
      guard let self, let theme = lastTheme, let revision = loadedUpdateRevision else { return }
      connectionFailure = true
      guard connectionRecovery.canRetry else { return }
      load(theme: theme, updateRevision: revision, recovering: true)
    }
    controller.onNavigationFinished = { [weak self] in
      self?.phase = .ready
      self?.connectionFailure = false
      self?.connectionRecovery.reset()
    }
    self.controller = controller
    return controller
  }

  func loadIfNeeded(theme: WebPaneThemeTokens, updateRevision: UInt64) {
    guard phase == .idle || loadedUpdateRevision != updateRevision else { return }
    load(theme: theme, updateRevision: updateRevision)
  }

  func retry(theme: WebPaneThemeTokens, updateRevision: UInt64) {
    connectionRecovery.reset()
    load(theme: theme, updateRevision: updateRevision, recovering: true)
  }

  func connectionDidChange(theme: WebPaneThemeTokens, updateRevision: UInt64) async {
    guard phase != .idle, phase != .loading else { return }
    if connectionFailure {
      if connectionRecovery.canRetry { load(theme: theme, updateRevision: updateRevision, recovering: true) }
      return
    }
    guard phase == .ready, let base = await resolveBaseURL(), !Task.isCancelled,
      phase == .ready, let loadedBaseURL, base != loadedBaseURL
    else { return }
    load(theme: theme, updateRevision: updateRevision)
  }

  func applyTheme(_ theme: WebPaneThemeTokens) {
    controller?.applyTheme(theme)
  }

  func revalidateAccess() async {
    do {
      guard let plugin = try await client.listPlugins().first(where: { $0.id == pluginId }) else {
        throw PluginAccessError("This plugin is no longer installed.")
      }
      try await access.requireAccess(to: plugin)
    } catch {
      guard !Task.isCancelled else { return }
      teardown()
      phase = .failed(ErrorReporter.userFacingMessage(for: error))
    }
  }

  private func load(theme: WebPaneThemeTokens, updateRevision: UInt64, recovering: Bool = false) {
    lastTheme = theme
    if !recovering { connectionRecovery.reset(); connectionFailure = false }
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
        guard let plugin = try await self.client.listPlugins().first(where: { $0.id == self.pluginId }) else {
          throw PluginAccessError("This plugin is no longer installed.")
        }
        try await self.access.requireAccess(to: plugin)
        guard !Task.isCancelled else { return }
        let response = try await self.client.issuePluginPaneToken(
          pluginId: self.pluginId,
          paneId: self.id.uuidString.lowercased(),
          paneType: self.paneType,
          workspaceId: self.workspaceId?.uuidString.lowercased(),
          cwd: self.cwd,
          themeMode: theme.mode
        )
        guard !Task.isCancelled else { return }
        let base = recovering ? await self.recoverConnection() : await self.resolveBaseURL()
        guard let base else {
          guard !Task.isCancelled else { return }
          self.phase = .failed(
            "This machine's relay connection isn't available yet. Try again once it reconnects."
          )
          return
        }
        guard !Task.isCancelled else { return }
        if recovering, !connectionRecovery.claimRetry() { return }
        guard let url = Self.paneURL(base: base, path: response.path) else {
          self.phase = .failed("The server returned an unusable pane address.")
          return
        }
        loadedBaseURL = base
        controller.load(url)
      } catch {
        guard !Task.isCancelled, !isTaskCancellation(error) else { return }
        controller.stopLoading()
        Log.plugins.error(
          "plugin pane token failed for \(self.pluginId, privacy: .public): \(String(describing: error), privacy: .public)"
        )
        self.phase = .failed(serverErrorMessage(error))
      }
    }
  }

  private static func paneURL(base: URL, path: String) -> URL? {
    let origin = base.absoluteString
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return URL(string: "\(origin)\(path)")
  }

  func teardown() {
    loadTask?.cancel()
    loadTask = nil
    controller?.stopLoading()
    controller = nil
    phase = .idle
    loadedBaseURL = nil
    connectionFailure = false
    connectionRecovery.reset()
  }
}

@MainActor
final class PluginPaneCache {
  static let shared = PluginPaneCache()

  private let retentionSeconds: TimeInterval = 300
  private let capacity = 4

  private var models: [UUID: PluginPaneModel] = [:]
  private var usageOrder: [UUID] = []
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

  func remove(paneId: UUID) {
    usageOrder.removeAll { $0 == paneId }
    lastUsed.removeValue(forKey: paneId)
    models.removeValue(forKey: paneId)?.teardown()
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
