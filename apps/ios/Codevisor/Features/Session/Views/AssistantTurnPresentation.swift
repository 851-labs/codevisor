/// The macOS assistant turn, ported: live "Working for Ns" sections that
/// stay open while streaming (chevron-less, like macOS), auto-collapse into
/// "Worked for Ns" when the turn ends, plan document between the planning
/// and implementation sections, recursive subagent sections, and the final
/// answer streaming below. Driven entirely by the turn's own state, so a
/// mid-stream turn loaded from history renders live too.
enum AssistantTurnPresentation {
    case complete
    case planning
    case result
    case completePrelude
    case resultPrelude
    case epilogue

    var showsPlanning: Bool {
        switch self {
        case .complete, .planning, .completePrelude: true
        case .result, .resultPrelude, .epilogue: false
        }
    }
    var showsPlanDocument: Bool { self == .complete }
    var showsResultWork: Bool {
        switch self {
        case .complete, .result, .completePrelude, .resultPrelude: true
        case .planning, .epilogue: false
        }
    }
    var showsActivity: Bool { showsResultWork }
    var showsResponse: Bool { self == .complete || self == .result }
    var showsEpilogue: Bool { showsResponse || self == .epilogue }
}
