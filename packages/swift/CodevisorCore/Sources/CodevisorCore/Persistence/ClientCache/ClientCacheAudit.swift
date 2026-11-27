import Foundation

enum ClientCacheAudit {
  struct Result: Equatable, Sendable {
    let subject: String
    let mismatches: [String]

    var matches: Bool { mismatches.isEmpty }
  }

  static func navigation(
    cached: ServerNavigationSnapshot?, expected: ServerNavigationSnapshot, machineId: String
  ) -> Result {
    guard let cached else { return Result(subject: "sidebar of \(machineId)", mismatches: ["nothing cached"]) }

    let mismatches = [
      compare("event cursor", [cached.eventCursor], [expected.eventCursor], id: String.init),
      compare("projects", cached.projects, expected.projects, id: \.id),
      compare("workspaces", cached.workspaces, expected.workspaces, id: \.id),
      compare("chats", cached.sessions, expected.sessions, id: \.id),
      compare("panes", cached.panes, expected.panes, id: \.id),
      compare("checkouts", cached.checkouts, expected.checkouts, id: \.id),
    ].compactMap(\.self)
    return Result(subject: "sidebar of \(machineId)", mismatches: mismatches)
  }

  static func transcript(cached: [UUID]?, shown: [UUID], chat: CachedChatKey) -> Result {
    let subject = "chat \(chat.chatId) on \(chat.machineId)"
    guard let cached else { return Result(subject: subject, mismatches: ["nothing cached"]) }

    let overlap = min(cached.count, shown.count)
    guard Array(cached.suffix(overlap)) != Array(shown.suffix(overlap)) else {
      return Result(subject: subject, mismatches: [])
    }

    let notShown = Set(cached).subtracting(shown).count
    let notCached = Set(shown.suffix(overlap)).subtracting(cached).count
    return Result(
      subject: subject, mismatches: ["\(notShown) cached items not shown, \(notCached) shown items not cached"])
  }

  static func log(_ result: Result, detail: String) {
    if result.matches {
      Log.clientCache.notice("Client cache matches \(result.subject, privacy: .public): \(detail, privacy: .public)")
    } else {
      Log.clientCache.fault(
        "Client cache differs from \(result.subject, privacy: .public): \(result.mismatches.joined(separator: "; "), privacy: .public)"
      )
    }
  }

  private static func compare<Record: Equatable>(
    _ label: String, _ cached: [Record], _ expected: [Record], id: (Record) -> String
  ) -> String? {
    let cached = NavigationRecordChanges.ordered(cached, id: id)
    let expected = NavigationRecordChanges.ordered(expected, id: id)
    guard cached != expected else { return nil }

    let changes = NavigationRecordChanges(new: expected, old: cached, id: id)
    return "\(label): \(changes.upserts.count) differ, \(changes.removedIds.count) extra"
  }
}
