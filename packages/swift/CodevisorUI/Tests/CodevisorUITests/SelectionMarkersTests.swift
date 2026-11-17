import Foundation
import Observation
import Testing
@testable import CodevisorUI

@MainActor
struct SelectionMarkersTests {
  @Test("Moving the selection notifies only the items that lose or gain it")
  func selectionNotifiesOnlyAffectedItems() {
    let markers = SelectionMarkers<UUID>()
    let (first, second, bystander) = (UUID(), UUID(), UUID())
    markers.select(first)
    let notified = NotifiedItems()
    for id in [first, second, bystander] {
      withObservationTracking {
        _ = markers.isSelected(id)
      } onChange: {
        notified.ids.append(id)
      }
    }

    markers.select(second)

    #expect(Set(notified.ids) == [first, second])
    #expect(!markers.isSelected(first))
    #expect(markers.isSelected(second))
    #expect(!markers.isSelected(bystander))
  }

  @Test("Clearing the selection leaves nothing selected")
  func clearingSelection() {
    let markers = SelectionMarkers<UUID>()
    let item = UUID()
    markers.select(item)

    markers.select(nil)

    #expect(!markers.isSelected(item))
  }
}

private final class NotifiedItems: @unchecked Sendable {
  var ids: [UUID] = []
}
