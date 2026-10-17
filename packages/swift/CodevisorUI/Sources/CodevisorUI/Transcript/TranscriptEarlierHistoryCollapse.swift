import CoreGraphics
import TranscriptKit

public struct TranscriptEarlierHistoryCollapse: Equatable {
  public let section: TranscriptWorkedSectionIdentity
  private let perform: @MainActor (_ change: @escaping () -> Void) -> Void

  public init(
    section: TranscriptWorkedSectionIdentity,
    perform: @escaping @MainActor (_ change: @escaping () -> Void) -> Void
  ) {
    self.section = section
    self.perform = perform
  }

  @MainActor public func callAsFunction(_ change: @escaping () -> Void) { perform(change) }

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.section == rhs.section }
}

public enum TranscriptEarlierHistoryCollapseTarget {
  public static func section(
    in layout: VirtualTranscriptLayout,
    rowByKey: [String: TranscriptVirtualRow],
    viewportTop: CGFloat,
    viewportBottom: CGFloat
  ) -> TranscriptWorkedSectionIdentity? {
    guard var index = layout.index(nearestToOffset: viewportTop) else { return nil }
    while layout.keys.indices.contains(index), layout.frame(at: index).minY <= viewportBottom {
      if let membership = rowByKey[layout.keys[index]]?.workedSection,
        revealsEarlierHistory(membership, at: index, in: layout, rowByKey: rowByKey)
      {
        return membership.identity
      }
      index += 1
    }
    return nil
  }

  public static func recentRowIndex(
    of section: TranscriptWorkedSectionIdentity,
    in layout: VirtualTranscriptLayout,
    rowByKey: [String: TranscriptVirtualRow]
  ) -> Int? {
    let recent = TranscriptWorkedSectionMembership(identity: section, role: .content)
    return layout.keys.firstIndex { rowByKey[$0]?.workedSection == recent }
  }

  private static func revealsEarlierHistory(
    _ membership: TranscriptWorkedSectionMembership,
    at index: Int,
    in layout: VirtualTranscriptLayout,
    rowByKey: [String: TranscriptVirtualRow]
  ) -> Bool {
    switch membership.role {
    case .earlierHistory:
      return true
    case .header, .earlierHistoryToggle:
      return false
    case .content:
      var previous = index - 1
      while previous >= 0,
        let earlier = rowByKey[layout.keys[previous]]?.workedSection,
        earlier.identity == membership.identity
      {
        switch earlier.role {
        case .earlierHistory: return true
        case .header, .earlierHistoryToggle: return false
        case .content: previous -= 1
        }
      }
      return false
    }
  }
}
