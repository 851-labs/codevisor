import Foundation
import ACPKit

@MainActor
final class SessionUpdateRoutes {
  private static let maximumRoutes = 1024

  private var ownerIds: [String: UUID] = [:]

  nonisolated static func persistedOwner(of update: SessionUpdate) -> UUID? {
    switch update {
    case let .agentMessagePatch(patch): patch.chatItemId.flatMap(UUID.init(uuidString:))
    case let .toolCall(call): call.chatItemId.flatMap(UUID.init(uuidString:))
    default: nil
    }
  }

  func owner(of update: SessionUpdate) -> UUID? {
    Self.persistedOwner(of: update) ?? toolCallOwner(of: update)
  }

  func record(_ update: SessionUpdate, owner: UUID, conversation: @autoclosure () -> [ConversationItem]) {
    if ownerIds.count > Self.maximumRoutes {
      ownerIds = Self.residentRoutes(ownerIds, in: conversation())
    }
    guard let toolCallId = Self.recordedToolCallId(of: update) else { return }

    ownerIds[toolCallId] = owner
  }

  func recordToolCalls(of message: AssistantMessage) {
    for call in message.turn.allToolCalls {
      ownerIds[call.toolCallId] = message.id
    }
  }

  func reassign(from previousOwner: UUID, to owner: UUID) {
    let routes = ownerIds.compactMap { route, current in
      current == previousOwner ? route : nil
    }
    for route in routes {
      ownerIds[route] = owner
    }
  }

  private func toolCallOwner(of update: SessionUpdate) -> UUID? {
    guard let keys = Self.routeKeys(of: update) else { return nil }

    return keys.parentToolCallId.flatMap { ownerIds[$0] } ?? keys.toolCallId.flatMap { ownerIds[$0] }
  }

  private nonisolated struct RouteKeys {
    var parentToolCallId: String?
    var toolCallId: String?
  }

  private nonisolated static func routeKeys(of update: SessionUpdate) -> RouteKeys? {
    switch update {
    case let .agentMessagePatch(patch):
      RouteKeys(parentToolCallId: patch.parentToolCallId)
    case let .agentMessageChunk(_, _, parent, _):
      RouteKeys(parentToolCallId: parent)
    case let .agentThoughtChunk(_, _, parent):
      RouteKeys(parentToolCallId: parent)
    case let .toolCall(call):
      RouteKeys(parentToolCallId: call.parentToolCallId, toolCallId: call.toolCallId)
    case let .toolCallUpdate(call):
      RouteKeys(parentToolCallId: call.parentToolCallId, toolCallId: call.toolCallId)
    default:
      nil
    }
  }

  private nonisolated static func recordedToolCallId(of update: SessionUpdate) -> String? {
    switch update {
    case let .toolCall(call): call.toolCallId
    case let .toolCallUpdate(call): call.toolCallId
    default: nil
    }
  }

  private nonisolated static func residentRoutes(
    _ routes: [String: UUID],
    in conversation: [ConversationItem]
  ) -> [String: UUID] {
    let resident = Set(conversation.flatMap(toolCallIds(in:)))
    return routes.filter { resident.contains($0.key) }
  }

  private nonisolated static func toolCallIds(in item: ConversationItem) -> [String] {
    guard case let .assistant(message) = item else { return [] }
    return message.turn.allToolCalls.map(\.toolCallId)
  }
}
