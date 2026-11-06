public struct SidebarModeSelections<Item: Hashable & Codable & Sendable>: Hashable, Codable, Sendable {
  public var chat: Item?
  public var code: Item?

  public init(chat: Item? = nil, code: Item? = nil) {
    self.chat = chat
    self.code = code
  }

  public subscript(mode: SidebarMode) -> Item? {
    get {
      switch mode {
      case .chat: chat
      case .code: code
      }
    }
    set {
      switch mode {
      case .chat: chat = newValue
      case .code: code = newValue
      }
    }
  }
}
