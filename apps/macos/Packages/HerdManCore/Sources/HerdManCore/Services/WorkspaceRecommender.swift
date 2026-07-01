import Foundation

/// A workspace suggestion derived from the user's existing harness sessions.
public struct WorkspaceRecommendation: Equatable, Sendable, Identifiable {
    public var folderURL: URL
    public var name: String
    public var sessionCount: Int
    public var lastActivity: Date?

    public var id: String { folderURL.path }

    public init(folderURL: URL, name: String, sessionCount: Int, lastActivity: Date? = nil) {
        self.folderURL = folderURL
        self.name = name
        self.sessionCount = sessionCount
        self.lastActivity = lastActivity
    }
}

/// Turns sessions discovered across harnesses (`session/list`) into a short
/// list of suggested project folders, most recently active first.
public enum WorkspaceRecommender {
    public static func recommend(
        from sessions: [ImportedSession],
        limit: Int = 2,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> [WorkspaceRecommendation] {
        var grouped: [String: (count: Int, lastActivity: Date?)] = [:]
        for session in sessions {
            let path = URL(fileURLWithPath: session.info.cwd).standardizedFileURL.path
            guard !path.isEmpty, path != "/" else { continue }
            let activity = session.info.updatedAt.flatMap(Self.date(from:))
            let existing = grouped[path]
            grouped[path] = (
                count: (existing?.count ?? 0) + 1,
                lastActivity: latest(existing?.lastActivity, activity)
            )
        }

        return grouped
            .filter { directoryExists($0.key) }
            .map { path, info in
                let url = URL(fileURLWithPath: path)
                return WorkspaceRecommendation(
                    folderURL: url,
                    name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                    sessionCount: info.count,
                    lastActivity: info.lastActivity
                )
            }
            .sorted { left, right in
                switch (left.lastActivity, right.lastActivity) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    if left.sessionCount != right.sessionCount {
                        return left.sessionCount > right.sessionCount
                    }
                    return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return max(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }

    private static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
