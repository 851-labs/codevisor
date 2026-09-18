import ScreenSharing
import Foundation
import QuartzCore

/// A bounded stdin/stdout clock responder for a trusted diagnostic SSH session.
/// The caller brackets each response with its own clock; no symmetry assumption
/// is required to derive an offset interval from a request's round-trip time.
enum ProbeClockSync {
  /// `arguments` are the probe's words; `--clock-sync` must be the only one.
  static func run(arguments: [String]) throws {
    guard arguments == ["--clock-sync"] else {
      throw ScreenSharingError.invalid("--clock-sync must run alone.")
    }
    for _ in 0..<10_000 {
      guard let line = readLine() else { return }
      let received = CACurrentMediaTime()
      guard let id = Int(line), (0...1_000_000).contains(id) else {
        throw ScreenSharingError.invalid("Clock requests require an integer identifier.")
      }
      let reply = Reply(id: id, receivedAtSeconds: received, sentAtSeconds: CACurrentMediaTime())
      var data = try JSONEncoder().encode(reply)
      data.append(0x0a)
      try FileHandle.standardOutput.write(contentsOf: data)
    }
  }

  private struct Reply: Encodable {
    let id: Int
    let receivedAtSeconds: Double
    let sentAtSeconds: Double
  }
}
