import Foundation
import Testing

@testable import CodevisorCore

/// Frames a terminal socket receives while the main actor is busy are
/// handed over in one batch, in order, with runs of output merged into one
/// renderer write.
@Suite("Terminal inbound frames")
struct TerminalInboundFramesTests {
  private func output(_ seq: Int, _ text: String, reset: Bool = false) -> TerminalInboundFrames.Item {
    .frame(
      InboundTerminalFrame(
        frame: TerminalServerFrame(type: "output", seq: seq, reset: reset ? true : nil),
        output: TerminalOutput(text: text)))
  }

  private func control(_ type: String, _ seq: Int) -> TerminalInboundFrames.Item {
    .frame(InboundTerminalFrame(frame: TerminalServerFrame(type: type, seq: seq), output: nil))
  }

  private func describe(_ items: [TerminalInboundFrames.Item]) -> [String] {
    items.map { item in
      guard case let .frame(inbound) = item else { return "failed" }
      let text = inbound.output.map { ":" + $0.text } ?? ""
      return "\(inbound.frame.type)#\(inbound.frame.seq)\(text)"
    }
  }

  @Test("A burst arrives as one ordered batch, output runs merged within history and within live output")
  func batchesInOrder() {
    let inbound = TerminalInboundFrames(liveBoundary: 3)
    // Only the first frame asks the main actor for a drain.
    #expect(inbound.append(output(1, "a")))
    #expect(!inbound.append(output(2, "b")))
    #expect(!inbound.append(output(3, "c")))
    #expect(!inbound.append(output(4, "d")))
    #expect(!inbound.append(control("size", 4)))
    #expect(!inbound.append(output(5, "e")))
    #expect(!inbound.append(output(6, "screen", reset: true)))
    #expect(!inbound.append(output(7, "f")))
    #expect(!inbound.append(.failed))

    let batch = inbound.take()
    #expect(
      describe(batch) == [
        "output#2:ab",  // history, never merged with live output
        "output#4:cd",
        "size#4",
        "output#5:e",
        "output#6:screen",  // a reset starts over; nothing merges into it
        "output#7:f",
        "failed",
      ])
    if case let .frame(merged) = batch[1] {
      #expect(merged.output?.bytes == Array("cd".utf8))
    }
    // Drained: the next frame asks for a drain again.
    #expect(inbound.append(output(8, "g")))
  }

  @Test("A torn-down socket's queue drops its frames and never holds the receive loop")
  func closeReleasesTheLoop() async {
    let inbound = TerminalInboundFrames(liveBoundary: 0)
    let large = String(repeating: "x", count: TerminalInboundFrames.byteLimit)
    #expect(inbound.append(output(1, large)))
    let loop = Task { await inbound.waitForCapacity() }
    inbound.close()
    await loop.value
    #expect(inbound.take().isEmpty)
    #expect(!inbound.append(output(2, "late")))
  }
}
