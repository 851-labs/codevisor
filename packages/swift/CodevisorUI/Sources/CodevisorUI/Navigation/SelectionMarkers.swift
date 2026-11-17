import Foundation
import Observation

@MainActor
public final class SelectionMarkers<ID: Hashable> {
  private var markers: [ID: SelectionMarker] = [:]
  private var selectedId: ID?

  public init() {}

  public func isSelected(_ id: ID) -> Bool {
    marker(for: id).isSelected
  }

  public func select(_ id: ID?) {
    guard id != selectedId else { return }

    if let selectedId { markers[selectedId]?.isSelected = false }
    selectedId = id
    if let id { marker(for: id).isSelected = true }
  }

  private func marker(for id: ID) -> SelectionMarker {
    if let marker = markers[id] { return marker }

    let marker = SelectionMarker(isSelected: id == selectedId)
    markers[id] = marker
    return marker
  }
}

public typealias WorkspaceNavigationTargets = SelectionMarkers<UUID>

@MainActor
@Observable
private final class SelectionMarker {
  var isSelected: Bool

  init(isSelected: Bool) {
    self.isSelected = isSelected
  }
}
