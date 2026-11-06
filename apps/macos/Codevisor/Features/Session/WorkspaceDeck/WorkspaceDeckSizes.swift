import CoreGraphics
import Observation

@Observable
final class WorkspaceDeckSizes {
  @ObservationIgnored var current: CGSize = .zero
  private var frozen: [WorkspaceDeckSlot: CGSize] = [:]

  func frozenSize(for slot: WorkspaceDeckSlot) -> CGSize? {
    frozen[slot]
  }

  func show(_ slot: WorkspaceDeckSlot?, hiding previous: WorkspaceDeckSlot?) {
    guard slot != previous else { return }

    if let previous, current != .zero {
      frozen[previous] = current
    }
    if let slot {
      frozen[slot] = nil
    }
  }

  func keep(_ mounted: Set<WorkspaceDeckSlot>) {
    guard frozen.keys.contains(where: { !mounted.contains($0) }) else { return }

    frozen = frozen.filter { mounted.contains($0.key) }
  }
}
