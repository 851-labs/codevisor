import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@Suite("ProjectRecommender")
struct ProjectRecommenderTests {
    private func session(
        _ id: String,
        cwd: String,
        updatedAt: String? = nil,
        harness: String = "claude-code"
    ) -> ImportedSession {
        ImportedSession(harnessId: harness, info: SessionInfo(sessionId: id, cwd: cwd, updatedAt: updatedAt))
    }

    @Test("Groups sessions by folder and ranks by recency")
    func groupsAndRanks() {
        let sessions = [
            session("a", cwd: "/src/old", updatedAt: "2026-01-01T00:00:00Z"),
            session("b", cwd: "/src/busy", updatedAt: "2026-06-01T00:00:00Z"),
            session("c", cwd: "/src/busy", updatedAt: "2026-06-20T12:30:00.123Z"),
            session("d", cwd: "/src/recent", updatedAt: "2026-06-10T00:00:00Z")
        ]

        let recommendations = ProjectRecommender.recommend(
            from: sessions,
            limit: 2,
            directoryExists: { _ in true }
        )

        #expect(recommendations.map(\.name) == ["busy", "recent"])
        #expect(recommendations.first?.sessionCount == 2)
        #expect(recommendations.first?.folderURL.path == "/src/busy")
    }

    @Test("Skips folders that no longer exist")
    func skipsMissingFolders() {
        let sessions = [
            session("a", cwd: "/src/gone", updatedAt: "2026-06-20T00:00:00Z"),
            session("b", cwd: "/src/kept", updatedAt: "2026-01-01T00:00:00Z")
        ]

        let recommendations = ProjectRecommender.recommend(
            from: sessions,
            limit: 2,
            directoryExists: { $0 == "/src/kept" }
        )

        #expect(recommendations.map(\.name) == ["kept"])
    }

    @Test("Falls back to session count and name without timestamps")
    func fallbackOrdering() {
        let sessions = [
            session("a", cwd: "/src/zebra"),
            session("b", cwd: "/src/alpha"),
            session("c", cwd: "/src/alpha"),
            session("d", cwd: "/src/dated", updatedAt: "2026-06-01T00:00:00Z")
        ]

        let recommendations = ProjectRecommender.recommend(
            from: sessions,
            limit: 3,
            directoryExists: { _ in true }
        )

        // Dated folders come first, then by chat count, then by name.
        #expect(recommendations.map(\.name) == ["dated", "alpha", "zebra"])
    }

    @Test("Ignores root and empty working directories and honors the limit")
    func ignoresDegenerateCwds() {
        let sessions = [
            session("a", cwd: "/"),
            session("b", cwd: "/src/one", updatedAt: "2026-06-03T00:00:00Z"),
            session("c", cwd: "/src/two", updatedAt: "2026-06-02T00:00:00Z"),
            session("d", cwd: "/src/three", updatedAt: "2026-06-01T00:00:00Z")
        ]

        let recommendations = ProjectRecommender.recommend(
            from: sessions,
            limit: 2,
            directoryExists: { _ in true }
        )

        #expect(recommendations.map(\.name) == ["one", "two"])
    }

    @Test("Attributes Codevisor-managed worktrees to their primary checkout")
    func resolvesManagedWorktrees() {
        let sessions = [
            session("root", cwd: "/Users/test/codevisor", updatedAt: "2026-07-03T00:00:00Z"),
            session("worktree", cwd: "/Users/test/codevisor/project-id/fix-auth", updatedAt: "2026-07-02T00:00:00Z"),
            session("similarly-named", cwd: "/Users/test/codevisor-project", updatedAt: "2026-07-01T00:00:00Z"),
            session("project", cwd: "/src/project", updatedAt: "2026-06-01T00:00:00Z")
        ]

        let recommendations = ProjectRecommender.recommend(
            from: sessions,
            limit: 4,
            managedWorktreesRoot: URL(fileURLWithPath: "/Users/test/codevisor"),
            directoryExists: { _ in true },
            linkedWorktreeRoot: {
                $0 == "/Users/test/codevisor/project-id/fix-auth" ? "/src/root-project" : nil
            }
        )

        #expect(
            recommendations.map(\.folderURL.path)
                == ["/src/root-project", "/Users/test/codevisor-project", "/src/project"]
        )
    }

    @Test("Attributes linked worktrees to their primary checkout and groups activity")
    func resolvesAndGroupsLinkedWorktrees() {
        let sessions = [
            session("worktree", cwd: "/src/app-fix-auth", updatedAt: "2026-07-03T00:00:00Z"),
            session("clone", cwd: "/src/app", updatedAt: "2026-07-02T00:00:00Z"),
            session("other", cwd: "/src/other", updatedAt: "2026-07-01T00:00:00Z")
        ]

        let recommendations = ProjectRecommender.recommend(
            from: sessions,
            limit: 4,
            directoryExists: { _ in true },
            linkedWorktreeRoot: { $0 == "/src/app-fix-auth" ? "/src/app" : nil }
        )

        #expect(recommendations.map(\.folderURL.path) == ["/src/app", "/src/other"])
        #expect(recommendations.first?.sessionCount == 2)
        #expect(recommendations.first?.lastActivity == ISO8601DateFormatter().date(from: "2026-07-03T00:00:00Z"))
    }

    @Test("Skips worktrees when the primary checkout no longer exists")
    func skipsMissingWorktreeRoots() {
        let sessions = [
            session("worktree", cwd: "/src/app-fix-auth", updatedAt: "2026-07-03T00:00:00Z"),
            session("project", cwd: "/src/project", updatedAt: "2026-07-02T00:00:00Z")
        ]

        let recommendations = ProjectRecommender.recommend(
            from: sessions,
            directoryExists: { _ in true },
            isLinkedWorktree: { $0 == "/src/app-fix-auth" },
            linkedWorktreeRoot: { _ in nil }
        )

        #expect(recommendations.map(\.folderURL.path) == ["/src/project"])
    }

    @Test("Resolves a primary checkout from Git worktree metadata")
    func resolvesGitWorktreeMetadata() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("project-recommender-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let root = scratch.appendingPathComponent("app", isDirectory: true)
        let gitDir = root
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("worktrees/fix-auth", isDirectory: true)
        let worktree = scratch.appendingPathComponent("app-fix-auth", isDirectory: true)
        try fileManager.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "../..\n".write(
            to: gitDir.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )

        #expect(ProjectRecommender.isLinkedWorktree(at: worktree.path))
        #expect(ProjectRecommender.linkedWorktreeRoot(at: worktree.path) == root.path)
    }
}
