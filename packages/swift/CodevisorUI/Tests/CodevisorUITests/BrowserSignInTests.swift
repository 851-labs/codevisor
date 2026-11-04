import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorUI

@MainActor
@Suite("Browser sign-in")
struct BrowserSignInTests {
  private let page = URL(string: "https://codevisor.example/login/github")!
  private let callback = URL(string: "codevisor-dev-0123456789://cloud-auth?ott=token")!

  @Test
  func signInCallbackFromTheBrowserFinishesTheWait() async {
    let rig = Rig()
    let waiting = rig.start(page)
    await rig.opened.wait()

    #expect(!rig.browser.receive(URL(string: "codevisor://device-approval?code=1")!))
    #expect(!rig.browser.receive(URL(string: "https://codevisor.example/cloud-auth")!))
    #expect(rig.browser.receive(callback))
    #expect(await waiting.value == callback)
    #expect(rig.urls == [page])
    #expect(!rig.browser.receive(callback))
  }

  @Test
  func callbackBringsBackTheWindowTheSignInStartedFrom() async {
    let rig = Rig()
    let waiting = rig.start(page)
    await rig.opened.wait()

    #expect(rig.browser.receive(callback))
    _ = await waiting.value
    await rig.restored.wait()

    #expect(rig.restored.value == 1)
  }

  @Test
  func returnLinkAfterTheWaitEndedStillBringsBackTheWindow() async {
    let rig = Rig()
    let id = UUID()
    let waiting = rig.start(page, id: id)
    await rig.opened.wait()
    rig.browser.cancel(id)
    _ = await waiting.value

    #expect(rig.browser.receive(URL(string: "codevisor://signed-in")!))
    await rig.restored.wait()
    #expect(!rig.browser.receive(callback))
  }

  @Test
  func startingAnotherSignInEndsTheEarlierWait() async {
    let rig = Rig()
    let first = rig.start(page)
    await rig.opened.wait()
    let second = rig.start(page)
    await rig.opened.wait(for: 2)

    #expect(await first.value == nil)
    #expect(rig.browser.receive(callback))
    #expect(await second.value == callback)
  }

  @Test
  func cancellingAnEndedAttemptLeavesTheCurrentOneWaiting() async {
    let rig = Rig()
    let stale = UUID()
    let first = rig.start(page, id: stale)
    await rig.opened.wait()
    let current = rig.start(page)
    await rig.opened.wait(for: 2)
    #expect(await first.value == nil)

    rig.browser.cancel(stale)

    #expect(rig.browser.receive(callback))
    #expect(await current.value == callback)
  }

  @Test
  func comingBackWithoutFinishingEndsTheWaitAfterTheGracePeriod() async {
    let rig = Rig()
    let waiting = rig.start(page)
    await rig.opened.wait()
    rig.post(BrowserSignIn.resignActive)
    rig.post(BrowserSignIn.becomeActive)
    await rig.clock.waitForSleep(BrowserSignIn.returnGrace)

    rig.clock.advance(by: BrowserSignIn.returnGrace)

    #expect(await waiting.value == nil)
  }

  @Test
  func callbackDuringTheGracePeriodStillCompletesTheSignIn() async {
    let rig = Rig()
    let waiting = rig.start(page)
    await rig.opened.wait()
    rig.post(BrowserSignIn.resignActive)
    rig.post(BrowserSignIn.becomeActive)
    await rig.clock.waitForSleep(BrowserSignIn.returnGrace)

    #expect(rig.browser.receive(callback))

    #expect(await waiting.value == callback)
    #expect(rig.clock.pendingCount == 0)
  }

  @Test
  func browserThatFailsToOpenEndsTheWait() async {
    let rig = Rig(opens: false)

    #expect(await rig.start(page).value == nil)
  }
}

@MainActor
private final class Rig {
  let clock = TestClock()
  let opened = TestSignal()
  let restored = TestSignal()
  let notifications = NotificationCenter()
  private(set) var urls: [URL] = []
  private(set) var browser: BrowserSignIn!

  init(opens: Bool = true) {
    browser = BrowserSignIn(
      open: { [unowned self] url in
        urls.append(url)
        opened.signal()
        return opens
      },
      rememberWindow: { [restored] in { restored.signal() } },
      clock: clock,
      notifications: notifications
    )
  }

  func start(_ url: URL, id: UUID = UUID()) -> Task<URL?, Never> {
    Task { await browser.run(url, id: id) }
  }

  func post(_ name: Notification.Name) {
    notifications.post(name: name, object: nil)
  }
}
