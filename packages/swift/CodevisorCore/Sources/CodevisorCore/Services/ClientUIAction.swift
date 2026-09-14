import Foundation

public struct ClientPageRequest: Codable, Sendable {
  public var page: String
  public var projectId: UUID?
  public var section: String?
}

public struct ClientWindowRequest: Codable, Sendable {
  public var action: String
  public var enabled: Bool?
  public var visible: Bool?
  public var x: Double?
  public var y: Double?
  public var width: Double?
  public var height: Double?
}

public struct ClientLayoutRequest: Codable, Sendable {
  public struct Action: Codable, Sendable {
    public var kind: String
    public var leafId: UUID?
    public var targetLeafId: UUID?
    public var edge: SplitEdge?
    public var tabId: UUID?
    public var branchPath: [Int]?
    public var fractions: [Double]?
    public var expectedChildren: [[UUID]]?
    public var tabIds: [UUID]?
    public var title: String?
  }
  public var workspaceId: UUID
  public var action: Action
  /// Background layout edits preserve selection unless explicitly requested.
  public var focus: Bool?
}

public enum ClientUIAction: Sendable {
  case page(ClientPageRequest)
  case layout(ClientLayoutRequest)
  case window(ClientWindowRequest)
}

public struct ClientPageContext: Codable, Sendable {
  public var page: String
  public var settingsSection: String?
  public var presentation: String?
  public init(page: String, settingsSection: String? = nil, presentation: String? = nil) {
    self.page = page
    self.settingsSection = settingsSection
    self.presentation = presentation
  }
}

public struct ClientWindowContext: Codable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public var isMinimized: Bool
  public var isFullscreen: Bool
  public var sidebarVisible: Bool

  public init(frame: CGRect, isMinimized: Bool, isFullscreen: Bool, sidebarVisible: Bool) {
    x = frame.origin.x; y = frame.origin.y
    width = frame.width; height = frame.height
    self.isMinimized = isMinimized
    self.isFullscreen = isFullscreen
    self.sidebarVisible = sidebarVisible
  }
}

public struct ClientCapabilities: Codable, Sendable {
  public var pages: [String]
  public var settingsSections: [String]
  public var layoutActions: [String]
  public var windowActions: [String]
  public init(settingsSections: [String], compact: Bool) {
    pages = ["home", "new_chat", "settings", "dismiss"]
    self.settingsSections = settingsSections
    layoutActions =
      ["new_tab", "reorder_tabs", "rename_tab"]
      + (compact ? [] : ["split", "move", "detach", "resize"])
    windowActions = compact ? [] : ["focus", "minimize", "restore", "fullscreen", "frame", "sidebar"]
  }
}
