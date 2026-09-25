import Foundation

/// A proposed plan splits a turn into two worked sections that read as two
/// consecutive responses: the work that produced the plan, then the work that
/// resumes once the user answers it. Each section owns its own live state and
/// duration; time spent waiting on the user belongs to neither.
extension AssistantTurn {
  /// Whether a plan splits this turn. A history snapshot carries the plan
  /// before its deferred work hydrates and restores `planBoundary`.
  var isSplitByPlan: Bool {
    planBoundary != nil || planDocument?.isEmpty == false
  }

  /// Whether the section shows a header that loads its work on expand
  /// before the turn's worked items have hydrated. History restores the work
  /// after a plan only once details load, so a turn that resumed after its
  /// plan keeps both sections visible from the first frame.
  public func defersWorkedSection(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard hasDeferredWorkedDetails else { return false }
    switch kind {
    case .planning: return true
    case .implementation: return planResumedAt != nil
    }
  }

  /// True while `kind` is the section currently receiving work. The planning
  /// section settles as soon as the plan lands, like a finished response.
  public func isWorkedSectionLive(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard isGenerating, !finalTextIsAsserted else { return false }
    switch kind {
    case .planning: return !isSplitByPlan
    case .implementation: return true
    }
  }

  /// When the section's work began: the turn start for planning, the user's
  /// answer to the plan for the work after it.
  public func workedSectionStart(_ kind: TranscriptWorkedSectionKind) -> Date? {
    switch kind {
    case .planning: startedAt
    case .implementation: planResumedAt ?? planProposedAt
    }
  }

  /// Wall-clock duration of a settled section, nil when unknown.
  public func workedSectionDuration(_ kind: TranscriptWorkedSectionKind) -> TimeInterval? {
    let end: Date? =
      switch kind {
      case .planning:
        !isSplitByPlan
          ? endedAt
          // History recorded before plan times existed: a turn that ended at
          // its plan (codex) still spans exactly the planning work.
          : planProposedAt ?? (planResumedAt == nil && workedItemsAfterPlan.isEmpty ? endedAt : nil)
      case .implementation: endedAt
      }
    guard let start = workedSectionStart(kind), let end else { return nil }
    return max(0, end.timeIntervalSince(start))
  }

  /// "Working for 12s" while live, "Worked for 12s" once settled.
  public func workedSectionTitle(_ kind: TranscriptWorkedSectionKind, now: Date) -> String {
    if workedSectionTicks(kind) {
      let start = workedSectionStart(kind) ?? now
      return "Working for \(Self.formatWorkedDuration(now.timeIntervalSince(start)))"
    }
    guard let duration = workedSectionDuration(kind) else {
      return isSplitByPlan ? "Worked" : "Worked for a moment"
    }
    guard duration >= 1 else { return "Worked for a moment" }
    return "Worked for \(Self.formatWorkedDuration(duration))"
  }

  /// Whether the section's title is a running timer. Unlike
  /// `isWorkedSectionLive`, it keeps counting while an asserted final answer
  /// streams: the response is still being produced.
  public func workedSectionTicks(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard isGenerating else { return false }
    switch kind {
    case .planning: return !isSplitByPlan
    case .implementation: return true
    }
  }

  static func formatWorkedDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.down)))
    return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
  }
}
