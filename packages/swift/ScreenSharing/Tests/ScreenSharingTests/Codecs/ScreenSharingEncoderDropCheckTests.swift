import CodevisorTestSupport
import Testing
@testable import ScreenSharing

/// The injected encoder fault. It holds no clock and no threshold of its own:
/// the probe arms it at the decoder's reset edge, and the completion of the
/// next forced keyframe consumes it exactly once, so one injected loss can
/// never become a stream of them. The app never arms it.
struct ScreenSharingEncoderDropCheckTests {
  @Test func anUnarmedCheckNeverDiscardsOutput() {
    let check = ScreenSharingEncoderDropCheck()
    for _ in 0..<3 { #expect(!check.consume()) }
  }

  @Test func oneArmDiscardsOneFrameHoweverOftenItIsArmed() {
    let check = ScreenSharingEncoderDropCheck()
    check.arm()
    // The probe can arm again before the encoder completes the frame it
    // already armed for; that must still cost the stream a single frame.
    check.arm()
    #expect(check.consume())
    #expect(!check.consume())
    check.arm()
    #expect(check.consume())
    #expect(!check.consume())
  }

  @Test func exactlyOneConcurrentCompletionDiscardsItsFrame() async {
    // VideoToolbox completes frames on its own queue, so completions can reach
    // the check together; whatever order they arrive in, one of them wins.
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
