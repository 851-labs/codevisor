import CodevisorCore

extension PaneKind {
  var tabFallbackSymbolName: String {
    switch self {
    case .chat: "text.bubble"
    case .terminal: "terminal"
    case .newTab: "square.dashed"
    case .plugin: "puzzlepiece.extension"
    case .document: "text.document"
    case .browser: "globe"
    case .screenSharing: "display"
    case .simulator: "iphone"
    case .subagent: "wand.and.sparkles"
    case .review: "plusminus"
    }
  }
}
