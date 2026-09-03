import Foundation

/// Resolves the value rendered by one identity-bound active row. A token flush
/// may use the live item, but a row from an older projection must keep showing
/// its own assistant after the model starts the next turn.
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
    // A provider can replace the locally-created active id with its
    // canonical transcript id before the next projection arrives. Unlike
    // a turn boundary, the projected id is not settled in that case, so
    // keep rendering the live bubble instead of flashing its old snapshot.
    return live ?? projected
  }
}
