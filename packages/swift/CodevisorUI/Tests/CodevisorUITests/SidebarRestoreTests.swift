import Testing
@testable import CodevisorUI

struct SidebarRestoreTests {
  private func restore(
    _ candidates: [String], orElse fallback: String? = "new chat", _ availability: [String: SidebarItemAvailability]
  ) -> SidebarRestore<String> {
    SidebarRestore.first(of: candidates, orElse: fallback) { availability[$0] ?? .gone }
  }

  @Test func selectsTheRememberedItemWhileItStillExists() {
    #expect(restore(["tab", "workspace"], ["tab": .available, "workspace": .available]) == .select("tab"))
  }

  @Test func fallsBackToTheNextCandidateWhenTheRememberedOneIsGone() {
    #expect(restore(["tab", "workspace"], ["workspace": .available]) == .select("workspace"))
  }

  @Test func fallsBackToTheModeDefaultWhenEveryCandidateIsGone() {
    #expect(restore(["tab", "workspace"], [:]) == .select("new chat"))
    #expect(restore([], orElse: nil, [:]) == .select(nil))
  }

  @Test func waitsWhileTheFirstLiveCandidateIsStillLoading() {
    #expect(restore(["bot", "recent bot"], ["bot": .pending, "recent bot": .available]) == .wait)
    #expect(restore(["bot", "recent bot"], ["recent bot": .pending]) == .wait)
  }
}
