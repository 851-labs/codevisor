import TranscriptKit

nonisolated struct SetupRequestCopy: Sendable {
  let request: TranscriptSetupRequest
  let handoffMachineName: String?
  let machineName: String?
  var chromeSetup: TranscriptChromeSetup = .dragIn

  var isPending: Bool { request.state == .pending }
  var canSetUpHere: Bool { handoffMachineName == nil }
  var installsFromWebStore: Bool { webStoreOldCopy != nil }

  var headline: String { isPending ? title : resolvedTitle }

  var title: String {
    switch request.kind {
    case .computerUse: "Allow Computer Use"
    case .chromeExtension: installsFromWebStore ? "Add Codevisor to Chrome" : "Connect Chrome"
    }
  }

  var setUpTitle: String { installsFromWebStore ? "Add to Chrome" : "Set Up" }

  var detail: String {
    if let handoffMachineName { return "Open Codevisor on \(handoffMachineName) to \(handoffTask)." }
    if let hasOldCopy = webStoreOldCopy { return webStoreDetail(hasOldCopy: hasOldCopy) }
    return switch request.kind {
    case .computerUse: "Codevisor needs Accessibility and Screen Recording on \(machine) to use your Mac."
    case .chromeExtension: "Add the Codevisor extension to Chrome on \(machine) so Codevisor can use your browser."
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

  private var machine: String {
    handoffMachineName ?? machineName ?? "this Mac"
  }

  private var handoffTask: String {
    switch request.kind {
    case .computerUse: "set up Computer Use"
    case .chromeExtension: "connect Chrome"
    }
  }

  private var webStoreOldCopy: Bool? {
    guard canSetUpHere, request.kind == .chromeExtension, case .webStore(let hasOldCopy) = chromeSetup else {
      return nil
    }
    return hasOldCopy
  }

  private func webStoreDetail(hasOldCopy: Bool) -> String {
    hasOldCopy ? "Remove the old Codevisor extension first." : "Let Codevisor work in your signed-in Chrome."
  }
}
