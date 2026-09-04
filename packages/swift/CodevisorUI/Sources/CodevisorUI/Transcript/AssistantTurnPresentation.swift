import Foundation
import TranscriptKit

/// Which chronological slice of an assistant turn a transcript row owns.
/// Active turns use `.complete`; settled plan turns split into planning and
/// result rows with `PlanDocumentView` virtualized independently between
/// them, and long turns split further into prelude, activity, and epilogue
/// slices so each row measures independently.
public enum AssistantTurnPresentation: Equatable, Sendable {
  case complete
  case planning
  case result
  case response
  case completePrelude
  case resultPrelude
  case activity
  case epilogue

  public var showsPlanning: Bool {
    switch self {
    case .complete, .planning, .completePrelude: true
    case .result, .response, .resultPrelude, .activity, .epilogue: false
    }
  }
  public var showsPlanDocument: Bool { self == .complete }
  public var showsResultWork: Bool {
    switch self {
    case .complete, .result, .completePrelude, .resultPrelude: true
    case .planning, .response, .activity, .epilogue: false
    }
  }
  public var showsActivity: Bool { showsResultWork || self == .activity }
  public var showsResponse: Bool { self == .complete || self == .result || self == .response }
  public var showsEpilogue: Bool { showsResponse || self == .epilogue }

  /// The slice a projected assistant chrome row renders.
  public init(chromeSlice: TranscriptAssistantChromeSlice) {
    switch chromeSlice {
    case .activity: self = .activity
    case .epilogue: self = .epilogue
    }
  }
}
