import CodevisorCore
import Foundation

@MainActor
final class McpOAuthSignIn {
  private struct Awaited {
    let serverId: String
    let machineId: String
    let browser: PluginSignInBrowser
  }

  private var awaited: Awaited?

  func run(_ browser: PluginSignInBrowser, at authorizationUrl: String, serverId: String, on machineId: String) async {
    awaited = Awaited(serverId: serverId, machineId: machineId, browser: browser)
    _ = await browser.finish(at: authorizationUrl)
    if awaited?.browser === browser { awaited = nil }
  }

  func closeIfConnected(_ servers: [ServerMcpServer], on machineId: String) {
    guard let awaited, awaited.machineId == machineId else { return }
    guard servers.contains(where: { $0.id == awaited.serverId && $0.connectionState == "connected" }) else { return }

    awaited.browser.close()
  }
}
