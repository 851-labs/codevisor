import Foundation

public enum TranscriptActiveItemResolver {
  public static func resolve(
    projected: ConversationItem,
    live: ConversationItem?,
    settled: [ConversationItem]
  ) -> ConversationItem {
    if live?.id == projected.id, let live {
      return live
    }
    if let settled = settled.last(where: { $0.id == projected.id }) {
      return settled
    }
    return live ?? projected
  }
}
