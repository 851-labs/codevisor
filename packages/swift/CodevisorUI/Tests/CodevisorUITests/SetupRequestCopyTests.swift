import Testing
import TranscriptKit

@testable import CodevisorUI

@Suite("Setup request copy")
struct SetupRequestCopyTests {
  private func copy(
    _ kind: TranscriptSetupRequest.Kind,
    _ state: TranscriptSetupRequest.State = .pending,
    handoff: String? = nil
  ) -> SetupRequestCopy {
    SetupRequestCopy(
      request: TranscriptSetupRequest(id: "setup", kind: kind, state: state),
      handoffMachineName: handoff,
      machineName: "Studio")
  }

  @Test("Each card names the machine it needs set up in one sentence")
  func localSentencesNameTheMachine() {
    #expect(
      copy(.computerUse).detail
        == "Codevisor needs Accessibility and Screen Recording on Studio to use your Mac.")
    #expect(
      copy(.chromeExtension).detail
        == "Add the Codevisor extension to Chrome on Studio so Codevisor can use your browser.")
    #expect(
      copy(.chromeExtensionUpdate).detail
        == "The Codevisor Chrome extension you have installed on Studio needs to be updated.")
  }

  @Test("Away from that machine, cards send the user there and say what needs doing")
  func handoffCards() {
    let update = copy(.chromeExtensionUpdate, handoff: "Build Mac")

    #expect(update.headline == "Chrome Extension Needs Update")
    #expect(update.detail == "Open Codevisor on Build Mac to update the Chrome extension.")
    #expect(!update.canSetUpHere)
    #expect(copy(.computerUse, handoff: "Build Mac").headline == "Allow Computer Use")
  }

  @Test("Resolved cards only name the outcome, and setup buttons drop the ellipsis")
  func resolvedCards() {
    #expect(copy(.chromeExtension, .setUp).headline == "Chrome connected")
    #expect(copy(.computerUse, .declined).headline == "Computer Use not allowed")
    #expect(copy(.chromeExtensionUpdate, .declined).headline == "Chrome extension not updated")
    #expect(copy(.computerUse).setUpTitle == "Set Up")
    #expect(copy(.chromeExtensionUpdate).setUpTitle == "Update")
  }
}
