import Testing
import TranscriptKit

@testable import CodevisorUI

@Suite("Setup request copy")
struct SetupRequestCopyTests {
  private func copy(
    _ kind: TranscriptSetupRequest.Kind,
    _ state: TranscriptSetupRequest.State = .pending,
    handoff: String? = nil,
    chromeSetup: TranscriptChromeSetup = .dragIn
  ) -> SetupRequestCopy {
    SetupRequestCopy(
      request: TranscriptSetupRequest(id: "setup", kind: kind, state: state),
      handoffMachineName: handoff,
      machineName: "Studio",
      chromeSetup: chromeSetup)
  }

  @Test("Each card names the machine it needs set up in one sentence")
  func localSentencesNameTheMachine() {
    #expect(
      copy(.computerUse).detail
        == "Codevisor needs Accessibility and Screen Recording on Studio to use your Mac.")
    #expect(
      copy(.chromeExtension).detail
        == "Add the Codevisor extension to Chrome on Studio so Codevisor can use your browser.")
  }

  @Test("Away from that machine, cards send the user there and say what needs doing")
  func handoffCards() {
    let chrome = copy(.chromeExtension, handoff: "Build Mac")

    #expect(chrome.headline == "Connect Chrome")
    #expect(chrome.detail == "Open Codevisor on Build Mac to connect Chrome.")
    #expect(!chrome.canSetUpHere)
    #expect(copy(.computerUse, handoff: "Build Mac").headline == "Allow Computer Use")
  }

  @Test("Resolved cards only name the outcome, and setup buttons drop the ellipsis")
  func resolvedCards() {
    #expect(copy(.chromeExtension, .setUp).headline == "Chrome connected")
    #expect(copy(.computerUse, .declined).headline == "Computer Use not allowed")
    #expect(copy(.chromeExtension, .declined).headline == "Chrome not connected")
    #expect(copy(.computerUse).setUpTitle == "Set Up")
  }

  @Test("Release builds ask to add Codevisor to Chrome from the Web Store, naming an old copy when one is in the way")
  func webStoreCards() {
    let fresh = copy(.chromeExtension, chromeSetup: .webStore(hasOldCopy: false))
    let blocked = copy(.chromeExtension, chromeSetup: .webStore(hasOldCopy: true))

    #expect(fresh.headline == "Add Codevisor to Chrome")
    #expect(fresh.detail == "Let Codevisor work in your signed-in Chrome.")
    #expect(fresh.setUpTitle == "Add to Chrome")
    #expect(blocked.detail == "Remove the old Codevisor extension first.")
    #expect(copy(.chromeExtension, .setUp, chromeSetup: .webStore(hasOldCopy: false)).headline == "Chrome connected")
    #expect(
      copy(.chromeExtension, handoff: "Build Mac", chromeSetup: .webStore(hasOldCopy: false)).headline
        == "Connect Chrome")
  }
}
