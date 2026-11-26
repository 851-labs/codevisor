import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
import Testing

@testable import ScreenSharingPane

@MainActor
@Suite("A Linux desktop on the phone", .timeLimit(.minutes(1)))
struct ScreenSharingLinuxDesktopTests {
  private static let centre = ScreenSharingPointer(x: 0.5, y: 0.5)

  @Test("A Linux desktop goes live through the server's relay, at its own size and with the pointer in the picture")
  func goesLive() async throws {
    let harness = try await LinuxDesktopHarness()
    defer { harness.stop() }

    let model = await harness.goLive()

    #expect(model?.selectedDisplay == LinuxDesktopHarness.display)
    #expect(harness.desktops.host.starts.isEmpty, "the relay is the session; the host starts nothing")
    let encodings = try #require(harness.advertisedEncodings)
    #expect(!encodings.contains(RFBEncoding.cursor.rawValue), "a server without this draws the pointer itself")
    #expect(encodings.contains(RFBEncoding.tight.rawValue))
    #expect(!harness.log.desktopReceived.contains { if case .setDesktopSize = $0 { true } else { false } })
  }

  @Test("A tap asks the server for control under the phone's name, and clicks once the server grants it")
  func tapTakesControl() async throws {
    let harness = try await LinuxDesktopHarness(controlLease: true)
    defer { harness.stop() }
    let model = await harness.goLive()

    model?.tap(at: Self.centre, location: .zero, time: 0)
    await awaitObserved { !harness.log.relayReceived.isEmpty }
    let request = try JSONSerialization.jsonObject(with: Data(harness.log.relayReceived[0].utf8)) as? [String: String]
    #expect(request == ["type": "request", "name": DesktopsHarness.appName])
    #expect(harness.input.isEmpty, "nothing reaches the desktop before the server grants control")

    harness.grantControl()
    await awaitObserved { harness.input.count == 3 }

    #expect(
      harness.input == [
        .pointerEvent(buttons: 0, x: 32, y: 24), .pointerEvent(buttons: 1, x: 32, y: 24),
        .pointerEvent(buttons: 0, x: 32, y: 24),
      ])
    #expect(model?.control?.state == .controlling)
  }

  @Test("When another device takes control, the phone stops controlling and says who took it")
  func anotherDeviceTakesControl() async throws {
    let harness = try await LinuxDesktopHarness(controlLease: true)
    defer { harness.stop() }
    let model = await harness.goLive()
    model?.tap(at: Self.centre, location: .zero, time: 0)
    await awaitObserved { !harness.log.relayReceived.isEmpty }
    harness.grantControl()
    await awaitObserved { model?.control?.state == .controlling }

    harness.revokeControl(by: "Alexandru's MacBook Pro")
    await awaitObserved { model?.control?.state == .idle }

    #expect(model?.control?.notice == "Alexandru's MacBook Pro took control.")
    #expect(model?.isViewing == true, "the picture stays; only control moved")
  }

  @Test("A two-finger tap right-clicks, and a two-finger drag turns the wheel")
  func rightClickAndScroll() async throws {
    let harness = try await LinuxDesktopHarness()
    defer { harness.stop() }
    let model = await harness.goLive()

    model?.secondaryClick(at: Self.centre)
    model?.scrolled(at: Self.centre, dx: 0, dy: 20)
    await awaitObserved { harness.input.count == 5 }

    #expect(
      harness.input == [
        .pointerEvent(buttons: 0, x: 32, y: 24), .pointerEvent(buttons: 4, x: 32, y: 24),
        .pointerEvent(buttons: 0, x: 32, y: 24), .pointerEvent(buttons: 8, x: 32, y: 24),
        .pointerEvent(buttons: 0, x: 32, y: 24),
      ])
  }

  @Test("A slow two-finger drag turns the wheel by the distance dragged, not once per movement")
  func slowScroll() async throws {
    let harness = try await LinuxDesktopHarness()
    defer { harness.stop() }
    let model = await harness.goLive()

    for _ in 0..<10 { model?.scrolled(at: Self.centre, dx: 0, dy: 4) }
    model?.tap(at: Self.centre, location: .zero, time: 0)
    await awaitObserved { harness.input.count == 7 }

    let wheelUp = RFBClientMessage.pointerEvent(buttons: 8, x: 32, y: 24)
    #expect(harness.input.filter { $0 == wheelUp }.count == 2, "40 pixels is two clicks")
  }

  @Test("Typed text arrives as the characters on the keys, and Command arrives as Control")
  func typing() async throws {
    let harness = try await LinuxDesktopHarness()
    defer { harness.stop() }
    let model = await harness.goLive()

    model?.type("H?")
    model?.toggle(.command)
    model?.type("c")
    model?.press(.returnKey)
    await awaitObserved { harness.input.count == 14 }

    #expect(
      harness.input == [
        .keyEvent(keysym: RFBKeysym.shiftLeft, down: true), .keyEvent(keysym: 0x48, down: true),
        .keyEvent(keysym: 0x48, down: false), .keyEvent(keysym: RFBKeysym.shiftLeft, down: false),
        .keyEvent(keysym: RFBKeysym.shiftLeft, down: true), .keyEvent(keysym: 0x3f, down: true),
        .keyEvent(keysym: 0x3f, down: false), .keyEvent(keysym: RFBKeysym.shiftLeft, down: false),
        .keyEvent(keysym: RFBKeysym.controlRight, down: true), .keyEvent(keysym: 0x63, down: true),
        .keyEvent(keysym: 0x63, down: false), .keyEvent(keysym: RFBKeysym.controlRight, down: false),
        .keyEvent(keysym: RFBKeysym.return, down: true), .keyEvent(keysym: RFBKeysym.return, down: false),
      ])
  }

  @Test("Every printable key on the phone's keyboard reaches Linux as the character it shows")
  func everyPrintableKey() {
    let keys = VNCKeyTranslator(layout: VNCUnitedStatesKeyLayout.layout)
    for scalar in (0x20...0x7e).compactMap(Unicode.Scalar.init) {
      let pressed = ScreenSharingKeyboard.type(String(Character(scalar)), modifiers: []).compactMap { event in
        guard case .key(let code, true, _, let modifiers) = event, ![55, 56, 58, 59].contains(code) else {
          return UInt32?.none
        }

        return keys.keysym(code: code, modifiers: modifiers)
      }
      #expect(pressed == [scalar.value], "\(scalar)")
    }
  }

  @Test("A machine whose server refuses the relay fails with the server's reason and Try Again, which connects")
  func failsThenRetries() async throws {
    let harness = try await LinuxDesktopHarness()
    defer { harness.stop() }
    harness.relayRefuses = true
    let model = harness.desktops.model()
    harness.desktops.show(model)
    await awaitObserved { model?.failure != nil }

    #expect(model?.failure?.sentence == "This machine has no VNC display.")
    #expect(model?.failure?.action == .tryAgain)

    harness.relayRefuses = false
    model?.retry()
    await harness.paintUntilLive(model, socketCount: 1)

    #expect(model?.failure == nil)
  }

  @Test("A dropped relay reconnects by itself and goes live again")
  func reconnectsAfterADrop() async throws {
    let harness = try await LinuxDesktopHarness()
    defer { harness.stop() }
    let model = await harness.goLive()

    harness.server.closeClient()
    await awaitObserved { model?.state == .reconnecting }
    await harness.paintUntilLive(model, socketCount: 2)

    #expect(model?.isViewing == true)
  }
}
