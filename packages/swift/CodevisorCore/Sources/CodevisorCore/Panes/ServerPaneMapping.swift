import Foundation

nonisolated enum ServerPaneMapping {
  static func record(
    from pane: PaneDescriptorState,
    workspaceId: UUID,
    createdAt: Date
  ) -> ServerWorkspacePane {
    let fields = PaneFormat.of(pane.kind).fields(pane)
    return ServerWorkspacePane(
      id: pane.id.uuidString,
      workspaceId: workspaceId.uuidString,
      providerId: fields.providerId,
      paneType: fields.paneType,
      title: pane.name,
      resourceKind: fields.resourceKind,
      resourceId: fields.resourceId,
      metadata: fields.metadata,
      createdAt: ServerDateCoding.string(from: createdAt)
    )
  }

  static func descriptor(from record: ServerWorkspacePane) -> PaneDescriptorState? {
    guard let id = UUID(uuidString: record.id) else { return nil }
    guard let format = PaneFormat.reading(record) else { return nil }

    return format.descriptor(record, id)
  }
}

private nonisolated struct PaneFields {
  var providerId = PaneFormat.codevisorProviderId
  var paneType: String
  var resourceKind: String?
  var resourceId: String?
  var metadata: String?
}

private nonisolated struct PaneFormat: Sendable {
  static let codevisorProviderId = "codevisor"
  static let pluginProviderPrefix = "plugin:"

  var paneTypes: Set<String> = []
  let fields: @Sendable (PaneDescriptorState) -> PaneFields
  let descriptor: @Sendable (ServerWorkspacePane, UUID) -> PaneDescriptorState?

  static func of(_ kind: PaneKind) -> PaneFormat {
    switch kind {
    case .chat: chat
    case .terminal: terminal
    case .newTab: deviceLocal("new-tab")
    case .subagent: deviceLocal("subagent")
    case .transcript: deviceLocal("transcript")
    case .browser: browser
    case .screenSharing: screenSharing
    case .review: review
    case .simulator: simulator
    case .document: document
    case .plugin: plugin
    }
  }

  static func reading(_ record: ServerWorkspacePane) -> PaneFormat? {
    if record.providerId.hasPrefix(pluginProviderPrefix) { return plugin }
    guard record.providerId == codevisorProviderId else { return nil }

    return PaneKind.allCases.lazy.map(of).first { $0.paneTypes.contains(record.paneType) }
  }

  private static let chat = PaneFormat(
    paneTypes: ["chat"],
    fields: { pane in
      PaneFields(
        paneType: "chat",
        resourceKind: pane.chatSessionId == nil ? nil : "session",
        resourceId: pane.chatSessionId?.uuidString
      )
    },
    descriptor: { record, id in
      let sessionId = chatSessionId(of: record)
      return PaneDescriptorState(
        id: id, kind: .chat, name: record.title,
        terminalKey: sessionId?.uuidString ?? id.uuidString, chatSessionId: sessionId)
    }
  )

  private static let terminal = PaneFormat(
    paneTypes: ["terminal"],
    fields: { PaneFields(paneType: "terminal", resourceKind: "terminal", resourceId: $0.terminalKey) },
    descriptor: { record, id in
      guard !isAttachOnly(record) else { return nil }

      return PaneDescriptorState(
        id: id, kind: .terminal, name: record.title,
        terminalKey: record.resourceId ?? id.uuidString,
        liveTitle: PaneDescriptorState.normalizedLiveTitle(record.liveTitle),
        terminalActivity: record.terminalActivity.flatMap(TerminalActivity.init(rawValue:)))
    }
  )

  private static func deviceLocal(_ paneType: String) -> PaneFormat {
    PaneFormat(
      paneTypes: [paneType],
      fields: { _ in PaneFields(paneType: paneType) },
      descriptor: { _, _ in nil }
    )
  }

  private static let browser = PaneFormat(
    paneTypes: ["browser"],
    fields: { PaneFields(paneType: "browser", metadata: metadataJSON(BrowserPaneMetadata(url: $0.browserURL))) },
    descriptor: { record, id in
      PaneDescriptorState(
        id: id, kind: .browser, name: record.title,
        terminalKey: id.uuidString, browserURL: metadata(BrowserPaneMetadata.self, of: record)?.url)
    }
  )

  private static let screenSharing = PaneFormat(
    paneTypes: ["screen-sharing"],
    fields: { pane in
      PaneFields(
        paneType: "screen-sharing",
        metadata: metadataJSON(pane.screenSharing ?? ScreenSharingPanePreferences()))
    },
    descriptor: { record, id in
      guard let preferences = metadata(ScreenSharingPanePreferences.self, of: record),
        preferences.schemaVersion == 1
      else { return nil }

      return PaneDescriptorState(
        id: id, kind: .screenSharing, name: record.title,
        terminalKey: id.uuidString, screenSharing: preferences)
    }
  )

  private static let review = PaneFormat(
    paneTypes: ["review"],
    fields: { PaneFields(paneType: "review", metadata: metadataJSON($0.review ?? ReviewPanePreferences())) },
    descriptor: { record, id in
      PaneDescriptorState(
        id: id, kind: .review, name: record.title,
        terminalKey: id.uuidString,
        review: metadata(ReviewPanePreferences.self, of: record) ?? ReviewPanePreferences())
    }
  )

  private static let simulator = PaneFormat(
    paneTypes: ["simulator"],
    fields: { pane in
      PaneFields(paneType: "simulator", metadata: metadataJSON(pane.simulator ?? SimulatorPanePreferences()))
    },
    descriptor: { record, id in
      let preferences = metadata(SimulatorPanePreferences.self, of: record)
      guard (preferences?.schemaVersion ?? 1) == 1 else { return nil }

      return PaneDescriptorState(
        id: id, kind: .simulator, name: record.title,
        terminalKey: id.uuidString, simulator: preferences ?? SimulatorPanePreferences())
    }
  )

  private static let document = PaneFormat(
    paneTypes: ["file", "markdown"],
    fields: { PaneFields(paneType: "file", resourceKind: "file", resourceId: $0.documentPath) },
    descriptor: { record, id in
      guard let path = filePath(of: record) else { return nil }

      return PaneDescriptorState(
        id: id, kind: .document, name: record.title,
        terminalKey: id.uuidString, documentPath: path)
    }
  )

  private static let plugin = PaneFormat(
    fields: { pane in
      PaneFields(
        providerId: pluginProviderPrefix + (pane.pluginId ?? "unknown"),
        paneType: pane.pluginPaneType ?? "pane")
    },
    descriptor: { record, id in
      let pluginId = String(record.providerId.dropFirst(pluginProviderPrefix.count))
      guard !pluginId.isEmpty else { return nil }

      return PaneDescriptorState(
        id: id, kind: .plugin, name: record.title,
        terminalKey: id.uuidString, pluginId: pluginId, pluginPaneType: record.paneType)
    }
  )

  private struct BrowserPaneMetadata: Codable { var url: String? }

  private struct LegacyTerminalMetadata: Decodable { var attachOnly: Bool? }

  private static func chatSessionId(of record: ServerWorkspacePane) -> UUID? {
    guard record.resourceKind == "session" else { return nil }

    return record.resourceId.flatMap(UUID.init(uuidString:))
  }

  private static func isAttachOnly(_ record: ServerWorkspacePane) -> Bool {
    metadata(LegacyTerminalMetadata.self, of: record)?.attachOnly == true
  }

  private static func filePath(of record: ServerWorkspacePane) -> String? {
    guard record.resourceKind == "file", let path = record.resourceId, !path.isEmpty else { return nil }

    return path
  }

  private static func metadataJSON<Value: Encodable>(_ value: Value) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }

    return String(data: data, encoding: .utf8)
  }

  private static func metadata<Value: Decodable>(_ type: Value.Type, of record: ServerWorkspacePane) -> Value? {
    record.metadata
      .flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONDecoder().decode(type, from: $0) }
  }
}
