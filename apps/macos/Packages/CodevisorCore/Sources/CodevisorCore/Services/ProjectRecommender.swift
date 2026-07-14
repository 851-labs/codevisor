import Foundation

/// A project suggestion derived from the user's existing harness sessions.
public struct ProjectRecommendation: Equatable, Sendable, Identifiable {
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

/// Turns sessions discovered across harnesses (`session/list`) into a list of
/// suggested project folders, most recently active first.
///
/// Sessions in linked Git worktrees are attributed to the primary checkout
/// when it still exists. This keeps short-lived worktree names out of the list
/// without throwing away the activity that makes their root project useful.
public enum ProjectRecommender {
    public static func recommend(
        from sessions: [ImportedSession],
        limit: Int = 12,
        managedWorktreesRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("codevisor", isDirectory: true),
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        isLinkedWorktree: (String) -> Bool = Self.isLinkedWorktree(at:),
        linkedWorktreeRoot: (String) -> String? = Self.linkedWorktreeRoot(at:)
    ) -> [ProjectRecommendation] {
        let worktreesRootPath = managedWorktreesRoot.standardizedFileURL.path
        var grouped: [String: (count: Int, lastActivity: Date?)] = [:]
        for session in sessions {
            let sessionPath = URL(fileURLWithPath: session.info.cwd).standardizedFileURL.path
            guard !sessionPath.isEmpty, sessionPath != "/" else { continue }

            let isManagedWorktreePath = sessionPath == worktreesRootPath
                || sessionPath.hasPrefix(worktreesRootPath + "/")
            let isLinkedWorktreePath = isLinkedWorktree(sessionPath)
            let resolvedRoot = linkedWorktreeRoot(sessionPath).map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
            // An unresolvable linked checkout is still temporary; do not
            // regress to suggesting its short-lived worktree folder.
            guard !isLinkedWorktreePath || resolvedRoot != nil else { continue }
            // Anything under Codevisor's worktree storage is temporary. Keep
            // it only when Git metadata can lead us back to a real checkout.
            guard !isManagedWorktreePath || resolvedRoot != nil else { continue }

            let path = resolvedRoot ?? sessionPath
            guard !path.isEmpty,
                  path != "/",
                  path != worktreesRootPath,
                  !path.hasPrefix(worktreesRootPath + "/"),
                  directoryExists(path)
            else { continue }

            let activity = session.info.updatedAt.flatMap(Self.date(from:))
            let existing = grouped[path]
            grouped[path] = (
                count: (existing?.count ?? 0) + 1,
                lastActivity: latest(existing?.lastActivity, activity)
            )
        }

        return grouped
            .map { path, info in
                let url = URL(fileURLWithPath: path)
                return ProjectRecommendation(
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

    @usableFromInline
    static func isLinkedWorktree(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let gitPath = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Resolves the primary checkout from the metadata Git writes into a
    /// linked worktree's `.git` file. A normal checkout has a `.git` directory
    /// and returns nil. Submodules and bare repositories intentionally return
    /// nil because their common Git directory does not identify an existing
    /// primary working tree.
    @usableFromInline
    static func linkedWorktreeRoot(at path: String) -> String? {
        let fileManager = FileManager.default
        let checkoutURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let dotGitURL = checkoutURL.appendingPathComponent(".git", isDirectory: false)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let dotGit = try? String(contentsOf: dotGitURL, encoding: .utf8),
              let gitDirValue = metadataPath(in: dotGit, key: "gitdir")
        else { return nil }

        let gitDirURL = resolvedURL(gitDirValue, relativeTo: checkoutURL)
        let commonDirFileURL = gitDirURL.appendingPathComponent("commondir", isDirectory: false)
        guard let commonDir = try? String(contentsOf: commonDirFileURL, encoding: .utf8),
              let commonDirValue = commonDir
                .split(whereSeparator: \Character.isNewline)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !commonDirValue.isEmpty
        else { return nil }

        let commonDirURL = resolvedURL(commonDirValue, relativeTo: gitDirURL)
        // Standard non-bare primary checkouts keep their common Git directory
        // at `<root>/.git`. Other layouts do not provide a safe root mapping.
        guard commonDirURL.lastPathComponent == ".git" else { return nil }
        let rootURL = commonDirURL.deletingLastPathComponent().standardizedFileURL
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue
        else { return nil }
        return rootURL.path
    }

    private static func metadataPath(in contents: String, key: String) -> String? {
        let prefix = "\(key):"
        guard let line = contents.split(whereSeparator: \Character.isNewline).first,
              line.hasPrefix(prefix)
        else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func resolvedURL(_ path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return baseURL.appendingPathComponent(path).standardizedFileURL
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
