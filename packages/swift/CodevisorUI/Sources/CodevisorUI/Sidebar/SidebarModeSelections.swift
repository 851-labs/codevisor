public struct SidebarModeSelections<Item: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
  public var bots: Item?
  public var code: Item?

  private enum CodingKeys: String, CodingKey {
    case bots = "chat"
    case code
  }

  public init(bots: Item? = nil, code: Item? = nil) {
    self.bots = bots
    self.code = code
  }

  public subscript(mode: SidebarMode) -> Item? {
    get {
      switch mode {
      case .bots: bots
      case .code: code
      }
    }
    set {
      switch mode {
      case .bots: bots = newValue
      case .code: code = newValue
      }
    }
  }
}
