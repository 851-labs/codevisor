import ACPKit
import TranscriptKit

public enum PluginSetupResolution: Equatable, Sendable {
  case connected
  case declined

  public static let declineLabel = "Not Now"

  public init?(_ answer: TranscriptQuestion.Answer?) {
    guard let answer else { return nil }
    self = Self.isDecline(answer) ? .declined : .connected
  }

  private static func isDecline(_ answer: TranscriptQuestion.Answer) -> Bool {
    answer.outcome == .cancelled || answer.entries.values.contains { $0.answers.contains(declineLabel) }
  }
}
