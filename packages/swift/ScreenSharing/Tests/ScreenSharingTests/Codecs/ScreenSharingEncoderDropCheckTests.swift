import CodevisorTestSupport
import Testing
@testable import ScreenSharing

struct ScreenSharingEncoderDropCheckTests {
  @Test func anUnarmedCheckNeverDiscardsOutput() {
    let check = ScreenSharingEncoderDropCheck()
    for _ in 0..<3 { #expect(!check.consume()) }
  }

  @Test func oneArmDiscardsOneFrameHoweverOftenItIsArmed() {
    let check = ScreenSharingEncoderDropCheck()
    check.arm()
    check.arm()
    #expect(check.consume())
    #expect(!check.consume())
    check.arm()
    #expect(check.consume())
    #expect(!check.consume())
  }

  @Test func exactlyOneConcurrentCompletionDiscardsItsFrame() async {
    let check = ScreenSharingEncoderDropCheck()
    let start = TestSignal()
    check.arm()
    let discarded = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<8 {
        group.addTask {
          await start.wait()
          return check.consume()
        }
      }
      start.signal()
      return await group.reduce(into: 0) { total, discarded in total += discarded ? 1 : 0 }
    }
    #expect(discarded == 1)
  }
}
