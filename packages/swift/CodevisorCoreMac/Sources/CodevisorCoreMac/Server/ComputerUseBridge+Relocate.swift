import AppKit
import ApplicationServices
import Foundation

func computerUseClosestCandidate(to frame: CGRect?, among candidates: [CGRect?]) -> Int? {
  guard !candidates.isEmpty else { return nil }
  if candidates.count == 1 { return 0 }
  guard let frame else { return nil }
  let distances = candidates.map { candidate in
    candidate.map { hypot($0.midX - frame.midX, $0.midY - frame.midY) } ?? .infinity
  }
  guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[best].isFinite else {
    return nil
  }
  return best
}

extension ComputerUseBridge {
  static let relocateNodeBudget = 4_000

  func relocate(_ record: ElementRecord, pid: pid_t, windowID: CGWindowID?) -> ElementRecord? {
    guard !record.identity.isEmpty else { return nil }
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 1)
    let windows = accessibleWindows(application)
    guard
      let root = windowID.flatMap({ id in windows.first { computerUseWindowID(for: $0) == id } })
        ?? windows.first
    else { return nil }
    return computerUsePerformAccessibilityRead(targetPID: pid) {
      var limits = ComputerUseSnapshotLimits(
        budget: ComputerUseReadBudget(budgetMilliseconds: 3_000), nodes: Self.relocateNodeBudget,
        records: .max, rowsPerList: .max)
      var matches: [(element: AXUIElement, frame: CGRect?)] = []
      var stack = [root]
      while let element = stack.popLast(), limits.admit(recordCount: 0) {
        let attributes = ComputerUseElementAttributes(element, names: ComputerUseElementAttributes.searchNames)
        if attributes.identity == record.identity { matches.append((element, frame(of: element))) }
        stack.append(contentsOf: attributes.children.reversed())
      }
      guard let best = computerUseClosestCandidate(to: record.frame, among: matches.map(\.frame)) else {
        return nil
      }
      return ElementRecord(element: matches[best].element, frame: matches[best].frame, identity: record.identity)
    }
  }
}
