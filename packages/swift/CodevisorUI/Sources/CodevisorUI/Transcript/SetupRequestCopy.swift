import TranscriptKit

nonisolated struct SetupRequestCopy: Sendable {
  let request: TranscriptSetupRequest
  let handoffMachineName: String?

  var isPending: Bool { request.state == .pending }
  var canSetUpHere: Bool { handoffMachineName == nil }

  var symbol: String {
    switch request.kind {
    case .computerUse: "macwindow.and.cursorarrow"
    case .chromeExtension: "puzzlepiece.extension"
    }
  }

  var title: String {
    switch request.kind {
    case .computerUse: "Allow Computer Use"
    case .chromeExtension: "Connect Chrome"
    }
  }

  var detail: String {
    if let handoffMachineName { return "Open Codevisor on \(handoffMachineName) to \(handoffTask)" }
    return switch request.kind {
    case .computerUse: "Accessibility, Screen Recording"
    case .chromeExtension: "Codevisor extension"
    }
  }

  private var handoffTask: String {
    switch request.kind {
    case .computerUse: "set up Computer Use"
    case .chromeExtension: "connect Chrome"
    }
  }

  var resolvedTitle: String {
    switch (request.kind, request.state) {
    case (.computerUse, .declined): "Computer Use not allowed"
    case (.chromeExtension, .declined): "Chrome not connected"
    case (.computerUse, _): "Computer Use allowed"
    case (.chromeExtension, _): "Chrome connected"
    }
  }
}
