import CodevisorCore
import Foundation

@MainActor
final class McpOAuthSignIn {
  private struct Awaited: Equatable {
    let serverId: String
    let machineId: String
  }

  private let presenter: any WebSignInPresenting
  private var awaited: Awaited?

  init(presenter: any WebSignInPresenting) {
    self.presenter = presenter
  }

  func run(_ url: URL, serverId: String, on machineId: String) async {
    let target = Awaited(serverId: serverId, machineId: machineId)
    awaited = target
    await presenter.run(url, callbackScheme: nil)
    if awaited == target { awaited = nil }
  }

  func closeIfConnected(_ servers: [ServerMcpServer], on machineId: String) {
    guard let awaited, awaited.machineId == machineId else { return }
    guard servers.contains(where: { $0.id == awaited.serverId && $0.connectionState == "connected" }) else { return }

    presenter.cancel()
  }
}
