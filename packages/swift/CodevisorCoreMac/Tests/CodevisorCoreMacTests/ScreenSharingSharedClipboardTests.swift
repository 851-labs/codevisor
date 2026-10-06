import AppKit
import ScreenSharing
import ScreenSharingTesting
import Testing

@testable import CodevisorCoreMac

/// Shared clipboard between the viewer's and the host's clipboards, each on its own pasteboard,
/// over a local channel whose deliveries the test runs.
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

  /// A Mac viewing itself: both sides share one pasteboard, so each write looks like a new copy.
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

    fixture.viewer.getRemoteText()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.local) == "there")
    #expect(fixture.viewer.message == "Remote text copied to this Mac’s clipboard.")
    fixture.copy("here again", to: fixture.local)
    fixture.viewer.sendLocalText()
    fixture.hop.drainAll()
    #expect(fixture.text(fixture.host) == "here again")
    #expect(!fixture.viewer.busy)
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

  init(onePasteboard: Bool = false) {
    local = NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    host = onePasteboard ? local : NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    channels = ScreenSharingLocalChannel.pair(hop: hop.schedule)
    let hostClipboard = ScreenSharingHostClipboard(
      channel: channels.1, pasteboard: .init(host), canReceiveUnsolicited: { true })
    self.hostClipboard = hostClipboard
    viewer = ScreenSharingViewerClipboard(
      channel: channels.0, pasteboard: .init(local), setHostSharing: { hostClipboard.setSharing($0) },
      hasKeyboardFocus: { [focus] in focus.on })
  }

  isolated deinit {
    local.releaseGlobally()
    host.releaseGlobally()
  }

  func copy(_ text: String, to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  func text(_ pasteboard: NSPasteboard) -> String? { pasteboard.string(forType: .string) }
}
