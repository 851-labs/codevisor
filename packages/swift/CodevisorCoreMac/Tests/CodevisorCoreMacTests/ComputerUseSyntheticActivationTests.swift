import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use synthetic activation")
struct ComputerUseSyntheticActivationTests {
  @Test("An app stays active until the last session using it releases it")
  func sharedHolds() {
    var holds = ComputerUseActivationHolds()
    holds.hold(pid: 42, sessionID: "a")
    holds.hold(pid: 42, sessionID: "b")
    holds.hold(pid: 7, sessionID: "a")
    #expect(holds.release(sessionID: "a") == [7])
    #expect(holds.isHeld(42))
    #expect(holds.release(sessionID: "b") == [42])
    #expect(!holds.isHeld(42))
    #expect(holds.release(sessionID: "b").isEmpty)
  }

  @Test("Activation records carry the event kind and the target window")
  func recordLayout() {
    let activated = computerUseActivationRecord(.activated, windowID: 0x0102_0304)
    #expect(activated.count == 0xf8)
    #expect(activated[0x04] == 0xf8)
    #expect(activated[0x08] == 0x0d)
    #expect(activated[0x8a] == 1)
    #expect(Array(activated[0x3c..<0x40]) == [0x04, 0x03, 0x02, 0x01])
    #expect(computerUseActivationRecord(.deactivated, windowID: 0)[0x8a] == 2)
  }

  @Test("Key-window records name the window so its menu shortcuts reach it in the background")
  func makeKeyLayout() {
    let records = computerUseMakeKeyRecords(windowID: 0x0102_0304)
    #expect(records.map { $0[0x08] } == [0x01, 0x02])
    for record in records {
      #expect(record.count == 0xf8 && record[0x3a] == 0x10)
      #expect(record[0x20..<0x30].allSatisfy { $0 == 0xff })
      #expect(Array(record[0x3c..<0x40]) == [0x04, 0x03, 0x02, 0x01])
    }
  }
}
