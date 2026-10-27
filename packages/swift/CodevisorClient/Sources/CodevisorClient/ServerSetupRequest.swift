import ACPKit
import Foundation
import TranscriptKit

public struct ServerSetupRequest: Decodable, Equatable, Sendable {
  public var questionId: String
  public var presentation: QuestionPresentation
  public var outcome: QuestionOutcome?

  var transcriptRequest: TranscriptSetupRequest? {
    guard let kind = TranscriptSetupRequest.kind(of: presentation) else { return nil }
    return TranscriptSetupRequest(id: questionId, kind: kind, state: state)
  }

  private var state: TranscriptSetupRequest.State {
    switch outcome {
    case nil: .pending
    case .cancelled: .declined
    case .answered, .autoResolved, .replied: .setUp
    }
  }
}
