import Foundation
import Testing

@testable import CodevisorCore

/// Local echo on slow links: typed characters show at once and give way to
/// the server's echo, without ever showing a guess where it would be wrong.
@Suite("Echo predictor")
struct EchoPredictorTests {
  private let start = ContinuousClock.now

  private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
    start.advanced(by: .milliseconds(milliseconds))
  }

  private func slowLink() -> EchoPredictor {
    var predictor = EchoPredictor()
    predictor.roundTripChanged(.milliseconds(120))
    return predictor
  }

  @Test("Predicts only on slow links, with hysteresis")
  func enablement() {
    var predictor = EchoPredictor()
    predictor.roundTripChanged(nil)
    predictor.typed("a", at: at(0))
    #expect(predictor.overlay(at: at(0)) == nil)

    predictor.roundTripChanged(.milliseconds(25))
    #expect(!predictor.isEnabled)
    predictor.roundTripChanged(.milliseconds(31))
    #expect(predictor.isEnabled)
    // Between the two thresholds, it stays on.
    predictor.roundTripChanged(.milliseconds(25))
    #expect(predictor.isEnabled)
    predictor.typed("x", at: at(0))
    predictor.roundTripChanged(.milliseconds(10))
    #expect(!predictor.isEnabled)
    #expect(predictor.overlay(at: at(0)) == nil)
  }

  @Test("Typed text shows until the echo confirms it, underlined once it lingers")
  func confirmsEcho() {
    var predictor = slowLink()
    predictor.typed("ls", at: at(0))
    #expect(predictor.overlay(at: at(10)) == .init(text: "ls", underlined: false))
    #expect(predictor.overlay(at: at(100)) == .init(text: "ls", underlined: true))
    // The echo may come wrapped in redraw controls.
    predictor.received("\u{1B}[?25ll")
    #expect(predictor.overlay(at: at(100))?.text == "s")
    predictor.received("s\u{1B}[?25h")
    #expect(predictor.overlay(at: at(100)) == nil)
    // Nothing pending: more output is just output.
    predictor.received("anything")
    let glitched = predictor.tick(at: at(1000))
    #expect(!glitched)
  }

  @Test("Backspace undoes its own guesses; Enter and control keys end them")
  func editing() {
    var predictor = slowLink()
    predictor.typed("abc\u{7F}", at: at(0))
    #expect(predictor.overlay(at: at(0))?.text == "ab")
    predictor.typed("\u{08}\u{08}\u{08}", at: at(0))
    #expect(predictor.overlay(at: at(0)) == nil)
    predictor.typed("xy\r", at: at(0))
    #expect(predictor.overlay(at: at(0)) == nil)
    predictor.typed("q\u{1B}[A", at: at(0))
    #expect(predictor.overlay(at: at(0)) == nil)
  }

  @Test("A mismatched echo drops the guesses")
  func mismatch() {
    var predictor = slowLink()
    predictor.typed("yes", at: at(0))
    predictor.received("*")
    #expect(predictor.overlay(at: at(0)) == nil)
  }

  @Test("An unechoed guess is a glitch that pauses predicting until the next line")
  func passwordPrompt() {
    var predictor = slowLink()
    predictor.typed("h", at: at(0))
    let early = predictor.tick(at: at(200))
    let late = predictor.tick(at: at(300))
    #expect(!early)
    #expect(late)
    #expect(predictor.overlay(at: at(300)) == nil)
    predictor.typed("unter2", at: at(310))
    #expect(predictor.overlay(at: at(310)) == nil)
    predictor.typed("\r", at: at(320))
    predictor.typed("ok", at: at(330))
    #expect(predictor.overlay(at: at(330))?.text == "ok")
  }

  @Test("Full-screen programs on the alternate screen get no guesses, even across split output")
  func alternateScreen() {
    var predictor = slowLink()
    predictor.typed("v", at: at(0))
    predictor.received("v\r\n\u{1B}[?10")
    predictor.received("49h\u{1B}[H")
    predictor.typed("j", at: at(0))
    #expect(predictor.overlay(at: at(0)) == nil)
    // Leaving it (with a lone ESC split off first) restores predicting.
    predictor.received("bye\u{1B}")
    predictor.received("[?1049l$ ")
    predictor.typed("l", at: at(0))
    #expect(predictor.overlay(at: at(0))?.text == "l")
    // Pending guesses are dropped when a program takes the screen.
    predictor.received("\u{1B}[")
    predictor.received("?47h")
    #expect(predictor.overlay(at: at(0)) == nil)
    // Other private modes and unrelated long sequences change nothing.
    predictor.received("\u{1B}[?1049l\u{1B}[?25h\u{1B}[?1;2;3;4;5;6;7;8;9;10;11;12")
    predictor.typed("m", at: at(0))
    #expect(predictor.overlay(at: at(0))?.text == "m")
  }
}
