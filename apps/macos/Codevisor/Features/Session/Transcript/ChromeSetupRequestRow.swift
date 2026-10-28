import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct ChromeSetupRequestRow: View {
  let request: TranscriptSetupRequest
  let inBotConversation: Bool
  let machineName: String
  let controller: SessionController

  @State private var configuration: ServerBrowserUseConfiguration?

  private static let refreshInterval: Duration = .seconds(2)

  private var chromeSetup: TranscriptChromeSetup {
    guard configuration?.installsFromWebStore ?? true else { return .dragIn }
    return .webStore(hasOldCopy: configuration?.unpackedExtensionInstalled == true)
  }

  private var icon: Image? {
    guard chromeSetup != .dragIn else { return nil }
    return Image(nsImage: NSApp.applicationIconImage)
  }

  var body: some View {
    TranscriptSetupRequestCard(
      request: request,
      inBotConversation: inBotConversation,
      handoffMachineName: nil,
      machineName: machineName,
      chromeSetup: chromeSetup,
      icon: icon,
      onSetUp: setUp,
      onDecline: { Task { await controller.declineSetupRequest(request.id) } }
    )
    .task(id: request.state) { await watchConfiguration() }
  }

  private func setUp() {
    guard chromeSetup != .dragIn else {
      controller.presentedSetupRequest = request
      return
    }
    Task { await controller.performBrowserExtensionSetupAction("Open Web Store") }
  }

  private func watchConfiguration() async {
    while request.state == .pending, !Task.isCancelled {
      if let latest = try? await controller.browserUseConfiguration() { configuration = latest }
      try? await Task.sleep(for: Self.refreshInterval)
    }
  }
}
