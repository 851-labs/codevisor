import Testing
@testable import CodevisorUI

struct SidebarRouteChangeTests {
  private func change(from old: SidebarRoute<String>, to new: SidebarRoute<String>) -> SidebarRouteChange {
    SidebarRouteChange(from: old, to: new, owner: owner(of:))
  }

  private func owner(of selection: String) -> SidebarMode? {
    if selection.hasPrefix("bot") { return .chat }
    if selection.hasPrefix("tab") { return .code }
    return nil
  }

  private func route(_ mode: SidebarMode, _ selection: String?) -> SidebarRoute<String> {
    SidebarRoute(mode: mode, selection: selection)
  }

  @Test func launchRestoresTheOpeningMode() {
    let launch = change(from: route(.chat, nil), to: route(.chat, nil))

    #expect(launch.remembers == nil)
    #expect(launch.restores == .chat)
  }

  @Test func selectingARowRemembersItForTheModeThatOwnsIt() {
    #expect(change(from: route(.code, "tab a"), to: route(.code, "tab b")).remembers == .code)
    #expect(change(from: route(.code, "tab a"), to: route(.code, "bot a")).remembers == .chat)
    #expect(change(from: route(.code, "tab a"), to: route(.code, "tab b")).restores == nil)
  }

  @Test func newChatIsRememberedOnlyAsACodeSelection() {
    #expect(change(from: route(.code, "tab a"), to: route(.code, "new chat")).remembers == .code)
    #expect(change(from: route(.chat, "bot a"), to: route(.chat, "new chat")).remembers == nil)
    #expect(change(from: route(.chat, "bot a"), to: route(.chat, nil)).remembers == nil)
  }

  @Test func flippingModesRestoresWithoutRememberingTheOtherModesPage() {
    let flip = change(from: route(.chat, "bot a"), to: route(.code, "bot a"))

    #expect(flip.remembers == nil)
    #expect(flip.restores == .code)
  }

  @Test func newChatFromChatModeIsRememberedBeforeCodeRestores() {
    let newChat = change(from: route(.chat, "bot a"), to: route(.code, "new chat"))

    #expect(newChat.remembers == .code)
    #expect(newChat.restores == .code)
  }
}
