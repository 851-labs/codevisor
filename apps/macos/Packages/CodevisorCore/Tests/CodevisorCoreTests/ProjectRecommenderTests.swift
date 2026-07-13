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

    @Test("Excludes Codevisor-managed worktrees")
    func excludesManagedWorktrees() {
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
            directoryExists: { _ in true }
        )

        #expect(recommendations.map(\.folderURL.path) == ["/Users/test/codevisor-project", "/src/project"])
    }

    @Test("Excludes linked git-worktree checkouts anywhere on disk")
    func excludesLinkedWorktrees() {
        let sessions = [
            session("worktree", cwd: "/src/app-fix-auth", updatedAt: "2026-07-03T00:00:00Z"),
            session("clone", cwd: "/src/app", updatedAt: "2026-07-02T00:00:00Z")
        ]

        let recommendations = ProjectRecommender.recommend(
            from: sessions,
            limit: 4,
            directoryExists: { _ in true },
            isLinkedWorktree: { $0 == "/src/app-fix-auth" }
        )

        #expect(recommendations.map(\.folderURL.path) == ["/src/app"])
    }
}
