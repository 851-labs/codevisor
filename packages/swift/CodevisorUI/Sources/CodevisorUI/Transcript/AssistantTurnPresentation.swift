import Foundation
import TranscriptKit

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

  public init(chromeSlice: TranscriptAssistantChromeSlice) {
    switch chromeSlice {
    case .activity: self = .activity
    case .epilogue: self = .epilogue
    }
  }
}
