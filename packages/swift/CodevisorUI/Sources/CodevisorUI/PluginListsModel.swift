import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
public final class PluginListsModel {
  public let subscriptions: PluginSubscriptionsModel
  public private(set) var isLoadingTools = false
  private var liveTools: [ServerMcpTool] = []

  @ObservationIgnored private let serverId: String
  @ObservationIgnored private let client: any CodevisorServerClienting

  public init(serverId: String, client: any CodevisorServerClienting) {
    self.serverId = serverId
    self.client = client
    subscriptions = PluginSubscriptionsModel(serverId: serverId, client: client)
  }

  public func lists(for server: ServerMcpServer) -> PluginCapabilityLists {
    guard let digest = server.capabilityDigest else { return PluginCapabilityLists(tools: liveTools) }
    return PluginCapabilityLists(capabilities: digest)
  }

  public func summaries(for server: ServerMcpServer) -> [PluginListSummary] {
    automationSummaries + capabilitySummaries(for: server)
  }

  public func loadTools(for server: ServerMcpServer) async {
    guard server.capabilityDigest == nil else { return }

    isLoadingTools = true
    defer { isLoadingTools = false }
    liveTools = (try? await client.listMcpTools(id: serverId)) ?? []
  }

  private var automationSummaries: [PluginListSummary] {
    let count = subscriptions.subscriptions.count
    return count > 0 ? [PluginListSummary(page: .automations, count: count)] : []
  }

  private func capabilitySummaries(for server: ServerMcpServer) -> [PluginListSummary] {
    guard server.capabilityDigest == nil else { return lists(for: server).summaries }
    return [PluginListSummary(page: .tools, count: liveTools.count, isLoading: isLoadingTools)]
  }
}
