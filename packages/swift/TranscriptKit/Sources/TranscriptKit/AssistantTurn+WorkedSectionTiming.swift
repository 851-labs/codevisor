import Foundation

extension AssistantTurn {
  var isSplitByPlan: Bool {
    planBoundary != nil || planDocument?.isEmpty == false
  }

  public func defersWorkedSection(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard hasDeferredWorkedDetails else { return false }
    switch kind {
    case .planning: return true
    case .implementation: return planResumedAt != nil
    }
  }

  public func isWorkedSectionLive(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard isGenerating, !finalTextIsAsserted else { return false }
    switch kind {
    case .planning: return !isSplitByPlan
    case .implementation: return true
    }
  }

  public func workedSectionStart(_ kind: TranscriptWorkedSectionKind) -> Date? {
    switch kind {
    case .planning: startedAt
    case .implementation: planResumedAt ?? planProposedAt
    }
  }

  public func workedSectionDuration(_ kind: TranscriptWorkedSectionKind) -> TimeInterval? {
    let end: Date? =
      switch kind {
      case .planning:
        !isSplitByPlan
          ? endedAt
          : planProposedAt ?? (planResumedAt == nil && workedItemsAfterPlan.isEmpty ? endedAt : nil)
      case .implementation: endedAt
      }
    guard let start = workedSectionStart(kind), let end else { return nil }
    return max(0, end.timeIntervalSince(start))
  }

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

  public func workedSectionTicks(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard isGenerating else { return false }
    switch kind {
    case .planning: return !isSplitByPlan
    case .implementation: return true
    }
  }

  public func showsLiveWorkedHeader(_ kind: TranscriptWorkedSectionKind) -> Bool {
    isWorkedSectionLive(kind) && (isThinking || hasProviderContent)
  }

  public func showsWorkedHeaderWithoutWork(_ kind: TranscriptWorkedSectionKind) -> Bool {
    guard hasProviderContent || (isGenerating && isThinking) else { return false }
    switch kind {
    case .planning: return !isSplitByPlan
    case .implementation: return planResumedAt != nil
    }
  }

  public var hasProviderContent: Bool {
    entries.contains { entry in
      if case .contextCompaction = entry { return false }
      return !entry.isBlankText
    }
  }

  public func showsWorkedThinkingLine(_ kind: TranscriptWorkedSectionKind) -> Bool {
    isGenerating && isThinking && showsLiveWorkedHeader(kind)
  }

  public func workedSectionElapsed(_ kind: TranscriptWorkedSectionKind, now: Date) -> String {
    Self.formatWorkedDuration(now.timeIntervalSince(workedSectionStart(kind) ?? now))
  }

  public static func formatWorkedDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.down)))
    return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
  }
}
