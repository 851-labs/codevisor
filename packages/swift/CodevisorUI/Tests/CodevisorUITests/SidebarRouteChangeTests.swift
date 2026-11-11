import Testing
@testable import CodevisorUI

struct SidebarRouteChangeTests {
  private func change(from old: SidebarRoute<String>, to new: SidebarRoute<String>) -> SidebarRouteChange {
    SidebarRouteChange(from: old, to: new, owner: owner(of:))
  }

  private func owner(of selection: String) -> SidebarMode? {
    if selection.hasPrefix("bot") { return .bots }
    if selection.hasPrefix("tab") { return .code }
    return nil
  }

  private func route(_ mode: SidebarMode, _ selection: String?) -> SidebarRoute<String> {
    SidebarRoute(mode: mode, selection: selection)
  }

  @Test func launchRestoresTheOpeningMode() {
    let launch = change(from: route(.bots, nil), to: route(.bots, nil))

    #expect(launch.remembers == nil)
    #expect(launch.restores == .bots)
  }

  @Test func selectingARowRemembersItForTheModeThatOwnsIt() {
    #expect(change(from: route(.code, "tab a"), to: route(.code, "tab b")).remembers == .code)
    #expect(change(from: route(.code, "tab a"), to: route(.code, "bot a")).remembers == .bots)
    #expect(change(from: route(.code, "tab a"), to: route(.code, "tab b")).restores == nil)
  }

  @Test func newChatIsRememberedOnlyAsACodeSelection() {
    #expect(change(from: route(.code, "tab a"), to: route(.code, "new chat")).remembers == .code)
    #expect(change(from: route(.bots, "bot a"), to: route(.bots, "new chat")).remembers == nil)
    #expect(change(from: route(.bots, "bot a"), to: route(.bots, nil)).remembers == nil)
  }

  @Test func flippingModesRestoresWithoutRememberingTheOtherModesPage() {
    let flip = change(from: route(.bots, "bot a"), to: route(.code, "bot a"))

    #expect(flip.remembers == nil)
    #expect(flip.restores == .code)
  }

  @Test func newChatFromChatModeIsRememberedBeforeCodeRestores() {
    let newChat = change(from: route(.bots, "bot a"), to: route(.code, "new chat"))

    #expect(newChat.remembers == .code)
    #expect(newChat.restores == .code)
  }
}
