import Foundation

/// The kinds of pane a session's pane groups can host. Future kinds (diff
/// viewers, previews, extensions, ...) add a case here plus a factory branch
/// in the app layer.
public enum PaneKind: String, Codable, Sendable {
  case terminal
  /// A chat session's transcript + composer. Lives in center groups;
  /// closing its tab archives the session.
  case chat
  /// The Chrome-style placeholder spawned when a group's last real pane
  /// closes: the empty state IS a tab (the strip never lies about what's
  /// open), and its page offers what to create. It leaves by conversion —
  /// picking New Chat/New Terminal replaces it in place.
  case newTab
  /// A plugin-contributed webview pane. The descriptor's plugin fields
  /// identify the plugin server and pane type; the app layer renders it
  /// through the server's plugin proxy.
  case plugin
  /// A file on the workspace’s machine. The persisted name retains compatibility with document panes.
  case document
  case browser
  case screenSharing
  /// A read-only view of one subagent's thread inside its parent chat.
  /// Device-local: never published to the server's pane registry, so other
  /// devices (and older builds) never see it. `ownerChatSessionId` is the
  /// parent chat; `subagentToolCallId` is the spawning tool call.
  case subagent
  /// A native diff of the workspace's working state (uncommitted, staged,
  /// branch, last turn, ...). Its preferences say what to compare.
  case review
  /// An Apple simulator on the workspace's Mac: its screen, hardware
  /// buttons and settings. The preferences say which device.
  case simulator

  /// Panes that exist only in this device's layout: never published to the
  /// server's pane registry, never pruned by server reconciliation.
  public var isDeviceLocal: Bool { self == .newTab || self == .subagent }
}

/// The persisted identity of one pane in a session's pane group. Pure data —
/// live pane objects (surfaces, PTY attachments) are built from this by the
/// app layer.
public struct PaneDescriptorState: Identifiable, Codable, Sendable, Equatable {
  public let id: UUID
  public let kind: PaneKind
  public var name: String
  /// The key the server's PTY manager stores this pane's shell under (the
  /// terminal create request's `sessionId`). The first pane of a session
  /// uses the bare chat-session UUID so it reattaches to shells created
  /// before panes existed; later panes use "<sessionUuid>:<paneUuid>".
  public let terminalKey: String
  /// Agent-owned background terminals: the pane only ever attaches to a
  /// terminal the server already registered (never spawns a shell), and the
  /// proxy's teardown must not kill the agent's process.
  public let attachOnly: Bool
  /// Chat panes only: the session this pane shows. A chat pane is a
  /// REFERENCE — the server owns the session; closing the pane never
  /// deletes it.
  public var chatSessionId: UUID?
  /// Agent-owned terminals only: the CHAT whose background task streams
  /// here. The workspace hosts every chat's task tabs, so
  /// pruning must be owner-scoped — chat B's empty snapshot must never
  /// tear down chat A's dev server.
  public var ownerChatSessionId: UUID?
  /// Plugin panes only: the owner-namespaced plugin id ("owner.name").
  public var pluginId: String?
  /// Plugin panes only: which of the plugin's pane types this renders.
  public var pluginPaneType: String?
  public var screenSharing: ScreenSharingPanePreferences?
  public var browserURL: String?
  public var documentPath: String?
  /// Review panes only: what the pane compares.
  public var review: ReviewPanePreferences?
  /// Simulator panes only: which device the pane shows.
  public var simulator: SimulatorPanePreferences?
  /// Terminal panes only: the title the running program set, from the
  /// server's pane record. Kept apart from `name`, which this client
  /// publishes back as the record's title.
  public var liveTitle: String?
  /// Terminal panes only, from the server's pane record like `liveTitle`:
  /// what an agent CLI running in the terminal is doing.
  public var terminalActivity: TerminalActivity?
  /// Subagent panes only: the tool call that spawned the subagent.
  public var subagentToolCallId: String?
  public init(
    id: UUID,
    kind: PaneKind,
    name: String,
    terminalKey: String,
    attachOnly: Bool = false,
    chatSessionId: UUID? = nil,
    ownerChatSessionId: UUID? = nil,
    pluginId: String? = nil,
    pluginPaneType: String? = nil,
    documentPath: String? = nil,
    browserURL: String? = nil,
    screenSharing: ScreenSharingPanePreferences? = nil,
    review: ReviewPanePreferences? = nil,
    simulator: SimulatorPanePreferences? = nil,
    liveTitle: String? = nil,
    terminalActivity: TerminalActivity? = nil,
    subagentToolCallId: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.terminalKey = terminalKey
    self.attachOnly = attachOnly
    self.chatSessionId = chatSessionId
    self.ownerChatSessionId = ownerChatSessionId
    self.pluginId = pluginId
    self.pluginPaneType = pluginPaneType
    self.documentPath = documentPath
    self.browserURL = browserURL
    self.screenSharing = screenSharing
    self.review = review
    self.simulator = simulator
    self.liveTitle = liveTitle
    self.terminalActivity = terminalActivity
    self.subagentToolCallId = subagentToolCallId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      kind: try container.decode(PaneKind.self, forKey: .kind),
      name: try container.decode(String.self, forKey: .name),
      terminalKey: try container.decode(String.self, forKey: .terminalKey),
      // Panes persisted before agent terminals existed are user shells.
      attachOnly: try container.decodeIfPresent(Bool.self, forKey: .attachOnly) ?? false,
      // Chat panes persisted before workspaces existed learn their
      // session id in the workspace backfill.
      chatSessionId: try container.decodeIfPresent(UUID.self, forKey: .chatSessionId),
      // Agent tabs persisted before owner scoping have no owner; any
      // syncer may manage them.
      ownerChatSessionId: try container.decodeIfPresent(UUID.self, forKey: .ownerChatSessionId),
      // Panes persisted before plugin panes existed carry no plugin
      // payload.
      pluginId: try container.decodeIfPresent(String.self, forKey: .pluginId),
      pluginPaneType: try container.decodeIfPresent(String.self, forKey: .pluginPaneType),
      documentPath: try container.decodeIfPresent(String.self, forKey: .documentPath),
      browserURL: try container.decodeIfPresent(String.self, forKey: .browserURL),
      screenSharing: try container.decodeIfPresent(ScreenSharingPanePreferences.self, forKey: .screenSharing),
      review: try container.decodeIfPresent(ReviewPanePreferences.self, forKey: .review),
      simulator: try container.decodeIfPresent(SimulatorPanePreferences.self, forKey: .simulator),
      liveTitle: try container.decodeIfPresent(String.self, forKey: .liveTitle),
      // Layouts persisted before terminal status carry none.
      terminalActivity: try container.decodeIfPresent(TerminalActivity.self, forKey: .terminalActivity),
      subagentToolCallId: try container.decodeIfPresent(String.self, forKey: .subagentToolCallId)
    )
  }

  /// The pane's own title: a terminal shows what is running in it, and plain
  /// "Terminal" otherwise (older panes were numbered "Terminal N"; the number
  /// told nothing apart). A name someone chose (a rename, an agent task's
  /// description) is deliberate, so the program's title never replaces it.
  /// Tab-level renames (`WorkspaceTab.customTitle`) take precedence over this.
  public var displayName: String {
    guard kind == .terminal, Self.isDefaultTerminalName(name) else { return name }
    return liveTitle ?? Self.defaultTerminalName
  }

  /// What a new terminal pane is called until something runs in it.
  public static let defaultTerminalName = "Terminal"

  /// Programs may set any string, including blank or multi-line titles; a
  /// tab label needs one trimmed line, and a blank title means "no title".
  static func normalizedLiveTitle(_ title: String?) -> String? {
    guard let title else { return nil }
    let line = title.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return line.isEmpty ? nil : line
  }

  private static func isDefaultTerminalName(_ name: String) -> Bool {
    guard name.hasPrefix("Terminal") else { return false }
    let suffix = name.dropFirst("Terminal".count)
    return suffix.isEmpty || (suffix.hasPrefix(" ") && Int(suffix.dropFirst()) != nil)
  }
}
