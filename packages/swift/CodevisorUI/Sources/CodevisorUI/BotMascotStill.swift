import CodevisorCore
import Foundation

struct BotMascotStill: Hashable, Sendable {
  enum Framing: String, Sendable {
    case portrait
    case figure
  }

  static let pixels = 384

  let mascot: ServerBotMascot
  let framing: Framing
  let pose: BotMascotMotion

  init(_ mascot: ServerBotMascot, framing: Framing, pose: BotMascotMotion = .idle) {
    self.mascot = mascot
    self.framing = framing
    self.pose = pose
  }

  var fileName: String {
    let parts = [
      framing.rawValue, pose.riveMode, mascot.color, mascot.hat, mascot.hatColor, mascot.eyewear, mascot.eyewearColor,
    ]
    return parts.map(Self.safe).joined(separator: "-") + ".png"
  }

  private static func safe(_ part: String) -> String {
    part.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? part
  }
}
