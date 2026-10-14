import Foundation

extension WorkspaceSyncModel {
  private struct BrowserPaneMetadata: Codable { var url: String? }

  private struct LegacyTerminalMetadata: Decodable { var attachOnly: Bool? }

  nonisolated static func serverPane(
    from pane: PaneDescriptorState,
    workspaceId: UUID,
    createdAt: Date
  ) -> ServerWorkspacePane {
    let paneType: String
    let resourceKind: String?
    let resourceId: String?
    var metadata: String?
    switch pane.kind {
    case .chat:
      paneType = "chat"
      resourceKind = pane.chatSessionId == nil ? nil : "session"
      resourceId = pane.chatSessionId?.uuidString
    case .terminal:
      paneType = "terminal"
      resourceKind = "terminal"
      resourceId = pane.terminalKey
    case .newTab:
      paneType = "new-tab"
      resourceKind = nil
      resourceId = nil
    case .subagent:
      paneType = "subagent"
      resourceKind = nil
      resourceId = nil
    case .browser:
      paneType = "browser"
      resourceKind = nil
      resourceId = nil
      if let data = try? JSONEncoder().encode(BrowserPaneMetadata(url: pane.browserURL)) {
        metadata = String(data: data, encoding: .utf8)
      }
    case .screenSharing:
      paneType = "screen-sharing"
      resourceKind = nil
      resourceId = nil
      if let data = try? JSONEncoder().encode(pane.screenSharing ?? ScreenSharingPanePreferences()) {
        metadata = String(data: data, encoding: .utf8)
      }
    case .review:
      paneType = "review"
      resourceKind = nil
      resourceId = nil
      if let data = try? JSONEncoder().encode(pane.review ?? ReviewPanePreferences()) {
        metadata = String(data: data, encoding: .utf8)
      }
    case .simulator:
      paneType = "simulator"
      resourceKind = nil
      resourceId = nil
      if let data = try? JSONEncoder().encode(pane.simulator ?? SimulatorPanePreferences()) {
        metadata = String(data: data, encoding: .utf8)
      }
    case .document:
      paneType = "file"
      resourceKind = "file"
      resourceId = pane.documentPath
    case .plugin:
      let pluginId = pane.pluginId ?? "unknown"
      let type = pane.pluginPaneType ?? "pane"
      return ServerWorkspacePane(
        id: pane.id.uuidString,
        workspaceId: workspaceId.uuidString,
        providerId: "plugin:\(pluginId)",
        paneType: type,
        title: pane.name,
        createdAt: ServerDateCoding.string(from: createdAt)
      )
    }
    return ServerWorkspacePane(
      id: pane.id.uuidString,
      workspaceId: workspaceId.uuidString,
      providerId: "codevisor",
      paneType: paneType,
      title: pane.name,
      resourceKind: resourceKind,
      resourceId: resourceId,
      metadata: metadata,
      createdAt: ServerDateCoding.string(from: createdAt)
    )
  }

  nonisolated static func descriptor(from record: ServerWorkspacePane) -> PaneDescriptorState? {
    guard let id = UUID(uuidString: record.id) else { return nil }
    if record.providerId.hasPrefix("plugin:") {
      let pluginId = String(record.providerId.dropFirst("plugin:".count))
      guard !pluginId.isEmpty else { return nil }
      return PaneDescriptorState(
        id: id,
        kind: .plugin,
        name: record.title,
        terminalKey: id.uuidString,
        pluginId: pluginId,
        pluginPaneType: record.paneType
      )
    }
    guard record.providerId == "codevisor" else { return nil }
    switch record.paneType {
    case "screen-sharing":
      guard let data = record.metadata?.data(using: .utf8),
        let preferences = try? JSONDecoder().decode(ScreenSharingPanePreferences.self, from: data),
        preferences.schemaVersion == 1
      else { return nil }
      return PaneDescriptorState(
        id: id, kind: .screenSharing, name: record.title,
        terminalKey: id.uuidString, screenSharing: preferences)
    case "simulator":
      let preferences = record.metadata.flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONDecoder().decode(SimulatorPanePreferences.self, from: $0) }
      guard (preferences?.schemaVersion ?? 1) == 1 else { return nil }
      return PaneDescriptorState(
        id: id, kind: .simulator, name: record.title,
        terminalKey: id.uuidString, simulator: preferences ?? SimulatorPanePreferences())
    case "browser":
      let value = record.metadata.flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONDecoder().decode(BrowserPaneMetadata.self, from: $0) }
      return PaneDescriptorState(
        id: id, kind: .browser, name: record.title,
        terminalKey: id.uuidString, browserURL: value?.url)
    case "review":
      let preferences = record.metadata.flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONDecoder().decode(ReviewPanePreferences.self, from: $0) }
      return PaneDescriptorState(
        id: id, kind: .review, name: record.title,
        terminalKey: id.uuidString, review: preferences ?? ReviewPanePreferences())
    case "file", "markdown":
      guard record.resourceKind == "file", let path = record.resourceId, !path.isEmpty else {
        return nil
      }
      return PaneDescriptorState(
        id: id, kind: .document, name: record.title,
        terminalKey: id.uuidString, documentPath: path
      )
    case "chat":
      let sessionId =
        record.resourceKind == "session"
        ? record.resourceId.flatMap(UUID.init(uuidString:))
        : nil
      return PaneDescriptorState(
        id: id,
        kind: .chat,
        name: record.title,
        terminalKey: sessionId?.uuidString ?? id.uuidString,
        chatSessionId: sessionId
      )
    case "terminal":
      let legacy = record.metadata
        .flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONDecoder().decode(LegacyTerminalMetadata.self, from: $0) }
      if legacy?.attachOnly == true { return nil }
      return PaneDescriptorState(
        id: id,
        kind: .terminal,
        name: record.title,
        terminalKey: record.resourceId ?? id.uuidString,
        liveTitle: PaneDescriptorState.normalizedLiveTitle(record.liveTitle),
        terminalActivity: record.terminalActivity.flatMap(TerminalActivity.init(rawValue:))
      )
    case "new-tab":
      return nil
    default:
      return nil
    }
  }
}
