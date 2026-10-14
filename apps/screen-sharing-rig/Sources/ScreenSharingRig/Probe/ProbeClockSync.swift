import ScreenSharing
import Foundation
import QuartzCore

enum ProbeClockSync {
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
