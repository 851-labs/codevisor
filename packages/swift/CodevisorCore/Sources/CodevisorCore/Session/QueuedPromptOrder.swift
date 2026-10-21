import Foundation

public enum QueuedPromptOrder {
  public static func moving(_ draggedID: String, onto targetID: String, in ids: [String]) -> [String] {
    guard let from = ids.firstIndex(of: draggedID), let to = ids.firstIndex(of: targetID), from != to else {
      return ids
    }
    var reordered = ids
    reordered.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    return reordered
  }
}
