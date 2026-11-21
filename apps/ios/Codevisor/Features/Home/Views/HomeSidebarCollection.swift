import SwiftUI
import UIKit

struct HomeSidebarCollection: UIViewRepresentable {
  enum Appearance: Equatable {
    case plain
    case sidebar

    var isConversation: Bool { self == .plain }
  }

  let rows: [HomeSidebarCollectionRow]
  let appearance: Appearance
  var selectedID: UUID?
  var isSelectable = false
  var animates = true
  var onMove: (_ source: Int, _ destination: Int) -> Void
  var onSelect: (UUID) -> Void
  var onRefresh: () async -> Void

  func makeCoordinator() -> HomeSidebarCollectionController {
    HomeSidebarCollectionController()
  }

  func makeUIView(context: Context) -> UICollectionView {
    context.coordinator.collectionView
  }

  func updateUIView(_ collectionView: UICollectionView, context: Context) {
    context.coordinator.update(with: self, environment: context.environment)
  }
}
