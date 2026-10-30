import CoreGraphics

public enum TranscriptSandboxPower: Hashable, Sendable {
  case paused(wakeFailure: String?)
  case waking

  var estimatedHeight: CGFloat {
    switch self {
    case .paused: 96
    case .waking: 32
    }
  }
}
