import TranscriptKit

nonisolated struct SetupRequestCopy: Sendable {
  let request: TranscriptSetupRequest
  let handoffMachineName: String?
  let machineName: String?

  var isPending: Bool { request.state == .pending }
  var canSetUpHere: Bool { handoffMachineName == nil }

  var symbol: String {
    switch request.kind {
    case .computerUse: "macwindow.and.cursorarrow"
    case .chromeExtension, .chromeExtensionUpdate: "puzzlepiece.extension"
    }
  }

  var title: String {
    switch request.kind {
    case .computerUse: "Allow Computer Use"
    case .chromeExtension: "Connect Chrome"
    case .chromeExtensionUpdate: canSetUpHere ? "Update Chrome Extension" : "Chrome Extension Needs Update"
    }
  }

  var setUpTitle: String {
    switch request.kind {
    case .chromeExtensionUpdate: "Update"
    case .computerUse, .chromeExtension: "Set Up…"
    }
  }

  var detail: String {
    if let handoffMachineName { return "Open Codevisor on \(handoffMachineName) to \(handoffTask)" }
    return switch request.kind {
    case .computerUse: "Accessibility, Screen Recording"
    case .chromeExtension: "Codevisor extension"
    case .chromeExtensionUpdate: updateDetail
    }
  }

  private var updateDetail: String {
    guard let machineName else { return "Codevisor extension" }
    return "The Codevisor Chrome extension you have installed on \(machineName) needs to be updated."
  }

  private var handoffTask: String {
    switch request.kind {
    case .computerUse: "set up Computer Use"
    case .chromeExtension: "connect Chrome"
    case .chromeExtensionUpdate: "update the Chrome extension"
    }
  }

  var resolvedTitle: String {
    switch (request.kind, request.state) {
    case (.computerUse, .declined): "Computer Use not allowed"
    case (.chromeExtension, .declined): "Chrome not connected"
    case (.chromeExtensionUpdate, .declined): "Chrome extension not updated"
    case (.computerUse, _): "Computer Use allowed"
    case (.chromeExtension, _): "Chrome connected"
    case (.chromeExtensionUpdate, _): "Chrome extension updated"
    }
  }
}
