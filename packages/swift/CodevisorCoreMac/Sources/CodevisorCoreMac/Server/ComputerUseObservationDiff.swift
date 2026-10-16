import Foundation

let computerUseDiffHeader = "Changes since the previous observation (~ changed, + added):"

func computerUseObservationText(current: String, previous: String?) -> String {
  guard let previous else { return current }
  let old = keyedObservationLines(previous)
  let new = keyedObservationLines(current)
  let oldLines = Dictionary(old.compactMap { entry in entry.id.map { ($0, entry.line) } }) { first, _ in first }
  let newIDs = Set(new.compactMap(\.id))
  let oldNotes = Set(old.filter { $0.id == nil }.map(\.line))
  var changes: [String] = []
  let removed = oldLines.keys.filter { !newIDs.contains($0) }.sorted()
  if !removed.isEmpty { changes.append("Removed element IDs: \(computerUseIDRanges(removed))") }
  appendObservationChanges(new, oldLines: oldLines, oldNotes: oldNotes, to: &changes)
  return changes.isEmpty
    ? "No changes since the previous observation." : ([computerUseDiffHeader] + changes).joined(separator: "\n")
}

private func keyedObservationLines(_ text: String) -> [(id: Int?, line: String)] {
  text.components(separatedBy: "\n").map { line in
    (Int(line.drop { $0 == " " }.prefix { $0 != " " }), line)
  }
}

private func appendObservationChanges(
  _ new: [(id: Int?, line: String)], oldLines: [Int: String], oldNotes: Set<String>,
  to changes: inout [String]
) {
  for (id, line) in new {
    if let id {
      if let before = oldLines[id] {
        if before != line { changes.append("~ " + line) }
      } else {
        changes.append("+ " + line)
      }
    } else if !oldNotes.contains(line) {
      changes.append("+ " + line)
    }
  }
}

func computerUseIDRanges(_ ids: [Int]) -> String {
  var ranges: [String] = []
  var index = 0
  while index < ids.count {
    var end = index
    while end + 1 < ids.count, ids[end + 1] == ids[end] + 1 { end += 1 }
    ranges.append(end == index ? "\(ids[index])" : "\(ids[index])-\(ids[end])")
    index = end + 1
  }
  return ranges.joined(separator: ", ")
}
