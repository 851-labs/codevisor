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

    var showsPlanning: Bool { self != .result }
    var showsPlanDocument: Bool { self == .complete }
    var showsResult: Bool { self != .planning }
}
