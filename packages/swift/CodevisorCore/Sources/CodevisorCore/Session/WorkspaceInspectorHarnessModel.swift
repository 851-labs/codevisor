import CodevisorClient
import CodevisorProtocol
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class WorkspaceInspectorHarnessModel {
  public struct Account: Hashable, Sendable {
    public let serverId: String
    public let harnessId: String
    public let accountId: String?

    public init(_ chat: ChatSession) {
      serverId = chat.serverId
      harnessId = chat.harnessId
      accountId = chat.harnessAccountId
    }
  }

  public struct Snapshot: Equatable, Sendable {
    public let limits: ServerHarnessUsageLimits?
    public let context: ServerSessionContext?
  }

  private struct Settled<Value: Sendable>: Sendable {
    let value: Value?
  }

  private var limits: [Account: Settled<ServerHarnessUsageLimits>] = [:]
  private var contexts: [UUID: Settled<ServerSessionContext>] = [:]

  public init() {}

  public func snapshot(for chat: ChatSession) -> Snapshot? {
    guard let limits = limits[Account(chat)], let context = contexts[chat.id] else { return nil }

    return Snapshot(limits: limits.value.flatMap(Self.shown), context: context.value)
  }

  public func load(_ chat: ChatSession, client: any CodevisorServerClienting, animated: Bool) async {
    async let limits = try? client.sessionUsageLimits(id: chat.id)
    async let context = try? client.sessionContext(id: chat.id)
    let fetched = await (limits: limits, context: context)
    guard !Task.isCancelled else { return }

    let animatesChange = animated && snapshot(for: chat) != nil
    withTransaction(\.disablesAnimations, !animatesChange) {
      settle(chat, limits: fetched.limits, context: fetched.context)
    }
  }

  public func prefetch(_ chats: [ChatSession], client: (String) -> any CodevisorServerClienting) async {
    var accounts = Set(limits.keys)
    let pending = chats.filter { accounts.insert(Account($0)).inserted }.map { ($0, client($0.serverId)) }
    await withTaskGroup(of: Void.self) { group in
      for (chat, client) in pending {
        group.addTask { await self.prefetchLimits(chat, client: client) }
      }
    }
  }

  private func prefetchLimits(_ chat: ChatSession, client: any CodevisorServerClienting) async {
    guard let fetched = try? await client.sessionUsageLimits(id: chat.id) else { return }

    limits[Account(chat)] = Settled(value: fetched)
  }

  private func settle(_ chat: ChatSession, limits fetched: ServerHarnessUsageLimits?, context: ServerSessionContext?) {
    let account = Account(chat)
    limits[account] = Settled(value: fetched ?? limits[account]?.value)
    contexts[chat.id] = Settled(value: context ?? contexts[chat.id]?.value)
  }

  private nonisolated static func shown(_ limits: ServerHarnessUsageLimits) -> ServerHarnessUsageLimits? {
    limits.state == "available" && !limits.windows.isEmpty ? limits : nil
  }
}
