import Foundation

/// Manual-order preference helpers for the Home navigation list — pure
/// string/ID transforms over the persisted newline-joined UUID lists.
func preferenceIDs(from rawValue: String) -> [UUID] {
  var seen: Set<UUID> = []
  return rawValue.split(separator: "\n").compactMap { rawID in
    guard let id = UUID(uuidString: String(rawID)), seen.insert(id).inserted else {
      return nil
    }
    return id
  }
}

func persistedIDs(from rawValue: String) -> Set<UUID> {
  Set(preferenceIDs(from: rawValue))
}

/// Updates the selected machine's visible slice without discarding ranks
/// saved for archived content or other paired machines.
func mergedPreferenceOrder(
  visibleIDs: [UUID],
  existingRawValue: String
) -> String {
  let visibleIDSet = Set(visibleIDs)
  let preservedIDs = preferenceIDs(from: existingRawValue).filter {
    !visibleIDSet.contains($0)
  }
  return (preservedIDs + visibleIDs).map(\.uuidString).joined(separator: "\n")
}

/// Applies a persistent manual rank while leaving newly-seen containers
/// in their source order at the end until the user moves them.
func manuallyOrdered<Value>(
  _ values: [Value],
  ids: [UUID],
  id: KeyPath<Value, UUID>
) -> [Value] {
  let ranks = Dictionary(
    uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }
  )
  return values.enumerated().sorted { left, right in
    let leftRank = ranks[left.element[keyPath: id]]
    let rightRank = ranks[right.element[keyPath: id]]
    switch (leftRank, rightRank) {
    case let (leftRank?, rightRank?): return leftRank < rightRank
    case (_?, nil): return true
    case (nil, _?): return false
    case (nil, nil): return left.offset < right.offset
    }
  }.map(\.element)
}
