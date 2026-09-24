import ACPKit
import Foundation
@testable import CodevisorCore

func navigationFixtureJSON(_ row: ServerWorkspacePane) -> JSONValue {
  try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(row))
}
func navigationFixtureJSON(_ row: ServerWorkspace) -> JSONValue {
  var object: [String: JSONValue] = [
    "id": .string(row.id), "projectId": .string(row.projectId), "serverId": .string(row.serverId),
    "name": .string(row.name), "hasCustomName": .bool(row.hasCustomName), "isArchived": .bool(row.isArchived),
    "createdAt": .string(row.createdAt),
  ]
  object["rootDirectory"] = row.rootDirectory.map(JSONValue.string)
  object["archivedAt"] = row.archivedAt.map(JSONValue.string)
  object["updatedAt"] = row.updatedAt.map(JSONValue.string)
  object["sidebarPosition"] = row.sidebarPosition.map(JSONValue.string)
  object["sidebarOrderRevision"] = row.sidebarOrderRevision.map { .number(Double($0)) }
  return .object(object)
}
func navigationFixtureJSON(_ row: ServerProject) -> JSONValue {
  .object([
    "id": .string(row.id), "name": .string(row.name),
    "origin": .string(row.origin.rawValue), "createdAt": .string(row.createdAt),
    "locations": .array(
      row.locations.map { location in
        .object([
          "id": .string(location.id), "projectId": .string(location.projectId), "serverId": .string(location.serverId),
          "folderPath": .string(location.folderPath), "createdAt": .string(location.createdAt),
          "isGitRepository": .bool(location.isGitRepository ?? false),
        ])
      }),
  ])
}
func navigationFixtureJSON(_ row: ServerSession) -> JSONValue {
  var object: [String: JSONValue] = [
    "id": .string(row.id), "projectId": .string(row.projectId), "serverId": .string(row.serverId),
    "harnessId": .string(row.harnessId), "title": .string(row.title), "origin": .string(row.origin.rawValue),
    "createdAt": .string(row.createdAt),
  ]
  object["workspaceId"] = row.workspaceId.map(JSONValue.string)
  object["agentSessionId"] = row.agentSessionId.map(JSONValue.string)
  object["sidebarState"] = row.sidebarState.map { .string($0.rawValue) }
  object["sidebarStateChangedAt"] = row.sidebarStateChangedAt.map(JSONValue.string)
  object["latestAttentionSequence"] = row.latestAttentionSequence.map { .number(Double($0)) }
  object["lastSeenAttentionSequence"] = row.lastSeenAttentionSequence.map { .number(Double($0)) }
  object["unreadCount"] = row.unreadCount.map { .number(Double($0)) }
  object["hasUnreadError"] = row.hasUnreadError.map(JSONValue.bool)
  object["pendingPlanApproval"] = row.pendingPlanApproval.map(JSONValue.bool)
  object["actionRequired"] = row.actionRequired.map(JSONValue.bool)
  object["worktreeName"] = row.worktreeName.map(JSONValue.string)
  return .object(object)
}
