import AppKit
import ScreenSharing
import ScreenSharingTesting
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingSharedClipboardTests {
  @Test func aCopyHereReachesTheHostOnlyWhileControllingWithFocusAndNeverComesBack() {
    let fixture = SharedClipboardFixture()
    fixture.copy("local copy", to: fixture.local)
    fixture.viewer.sharing = true
    fixture.viewer.poll()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.host) == nil, "not controlling")

    fixture.focus.on = false
    fixture.viewer.setControlling(true)
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.host) == nil, "the video doesn't have keyboard focus")

    fixture.focus.on = true
    fixture.viewer.poll()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.host) == "local copy")

    let local = fixture.local.changeCount
    let host = fixture.host.changeCount
    fixture.hostClipboard.poll()
    fixture.viewer.poll()
    fixture.hop.drainAll()
    #expect(fixture.local.changeCount == local && fixture.host.changeCount == host)
  }

  @Test func aCopyOnTheHostReachesThisMacOnlyIfMadeAfterSharingStarted() {
    let fixture = SharedClipboardFixture()
    fixture.focus.on = false
    fixture.copy("older host copy", to: fixture.host)
    fixture.viewer.sharing = true
    fixture.viewer.setControlling(true)
    fixture.hostClipboard.poll()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.local) == nil)

    fixture.copy("host copy", to: fixture.host)
    fixture.hostClipboard.poll()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.local) == "host copy")

    let host = fixture.host.changeCount
    fixture.focus.on = true
    fixture.viewer.poll()
    fixture.hop.drainAll()
    #expect(fixture.host.changeCount == host, "the copy it wrote doesn't go back")
  }

  @Test func onOnePasteboardACopySettlesInsteadOfGoingRound() {
    let fixture = SharedClipboardFixture(onePasteboard: true)
    fixture.viewer.sharing = true
    fixture.viewer.setControlling(true)
    fixture.copy("copy", to: fixture.local)
    fixture.viewer.poll()
    fixture.hop.drainAll()
    let settled = fixture.local.changeCount
    for _ in 0..<3 {
      fixture.viewer.poll()
      fixture.hostClipboard.poll()
      fixture.hop.drainAll()
    }
    #expect(fixture.local.changeCount == settled)
    #expect(fixture.text(fixture.local) == "copy")
  }

  @Test func aConcealedCopyIsNeverShared() {
    let fixture = SharedClipboardFixture()
    fixture.local.clearContents()
    fixture.local.setString("hunter2", forType: .string)
    fixture.local.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    fixture.viewer.sharing = true
    fixture.viewer.setControlling(true)
    fixture.viewer.poll()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.host) == nil)
  }

  @Test func whenBothMacsCopyAtOnceTheViewersCopyWins() {
    let fixture = SharedClipboardFixture()
    fixture.viewer.sharing = true
    fixture.viewer.setControlling(true)
    fixture.hop.drainAll()
    fixture.copy("here", to: fixture.local)
    fixture.copy("there", to: fixture.host)
    fixture.viewer.poll()
    fixture.hostClipboard.poll()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.local) == "here" && fixture.text(fixture.host) == "here")
  }

  @Test func withSharingOffOnlyTheMenuMovesText() {
    let fixture = SharedClipboardFixture()
    fixture.viewer.setControlling(true)
    fixture.copy("there", to: fixture.host)
    fixture.copy("here", to: fixture.local)
    fixture.hostClipboard.poll()
    fixture.viewer.poll()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.local) == "here" && fixture.text(fixture.host) == "there")

    fixture.viewer.getRemoteClipboard()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.local) == "there")
    #expect(fixture.viewer.message == "Remote clipboard copied to this Mac.")
    fixture.copy("here again", to: fixture.local)
    fixture.viewer.sendLocalClipboard()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.host) == "here again")
    #expect(!fixture.viewer.busy)
  }

  @Test func anImageCopiedOnEitherMacIsPastableOnTheOther() {
    let fixture = SharedClipboardFixture()
    fixture.viewer.sharing = true
    fixture.viewer.setControlling(true)
    let screenshot = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
    fixture.copy(png: screenshot, text: "Screenshot", to: fixture.local)
    fixture.viewer.poll()
    fixture.hop.drainAll()
    #expect(fixture.host.data(forType: .png) == screenshot)
    #expect(fixture.text(fixture.host) == "Screenshot")

    let remote = Data(screenshot.reversed())
    fixture.copy(png: remote, text: nil, to: fixture.host)
    fixture.hostClipboard.poll()
    fixture.hop.drainAll()
    #expect(fixture.local.data(forType: .png) == remote)
    #expect(fixture.text(fixture.local) == nil)
  }

  @Test func aHostThatPredatesRichContentStillReceivesTheText() {
    let fixture = SharedClipboardFixture(hostRichContent: false)
    fixture.viewer.sharing = true
    fixture.viewer.setControlling(true)
    fixture.copy(png: Data([1, 2, 3]), text: "caption", to: fixture.local)
    fixture.viewer.poll()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.host) == "caption")
    #expect(fixture.host.data(forType: .png) == nil)

    let host = fixture.host.changeCount
    fixture.copy(png: Data([4, 5, 6]), text: nil, to: fixture.local)
    fixture.viewer.poll()
    fixture.hop.drainAll()
    #expect(fixture.host.changeCount == host)
  }
}

@MainActor
private final class SharedClipboardFixture {
  final class Focus { var on = true }
  let hop = ScreenSharingManualHop()
  let local: NSPasteboard
  let host: NSPasteboard
  let focus = Focus()
  let viewer: ScreenSharingViewerClipboard
  let hostClipboard: ScreenSharingHostClipboard
  private let channels:
    (ScreenSharingLocalChannel<ScreenSharingClipboardMessage>, ScreenSharingLocalChannel<ScreenSharingClipboardMessage>)

  init(onePasteboard: Bool = false, hostRichContent: Bool = true) {
    local = NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    host = onePasteboard ? local : NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    channels = ScreenSharingLocalChannel.pair(hop: hop.schedule)
    let hostClipboard = ScreenSharingHostClipboard(
      channel: channels.1, pasteboard: .init(host), canReceiveUnsolicited: { true })
    self.hostClipboard = hostClipboard
    viewer = ScreenSharingViewerClipboard(
      channel: channels.0, pasteboard: .init(local),
      setHostSharing: { _ = hostClipboard.receive(.viewer(sharing: $0, richContent: hostRichContent ? true : nil)) },
      hasKeyboardFocus: { [focus] in focus.on })
    if hostRichContent, hostClipboard.receive(.viewer(sharing: false, richContent: true)) == .host(richContent: true) {
      viewer.hostAcceptsRichContent()
    }
  }

  isolated deinit {
    local.releaseGlobally()
    host.releaseGlobally()
  }

  func copy(_ text: String, to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  func copy(png: Data, text: String?, to pasteboard: NSPasteboard) {
    let item = NSPasteboardItem()
    item.setData(png, forType: .png)
    if let text { item.setString(text, forType: .string) }
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
  }

  func text(_ pasteboard: NSPasteboard) -> String? { pasteboard.string(forType: .string) }
}
