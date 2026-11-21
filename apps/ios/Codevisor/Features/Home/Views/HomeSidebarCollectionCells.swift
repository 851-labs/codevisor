import SwiftUI
import UIKit

final class HomeSidebarCollectionCells {
  typealias Row = HomeSidebarCollectionRow

  var environment = EnvironmentValues()
  var select: (UUID) -> Void = { _ in }

  func configure(_ cell: UICollectionViewListCell, row: Row, appearance: HomeSidebarCollection.Appearance) {
    let environment = environment
    let select = select
    let isSidebar = appearance == .sidebar
    cell.configurationUpdateHandler = { cell, state in
      guard let cell = cell as? UICollectionViewListCell else { return }
      cell.backgroundConfiguration = Self.background(row, cell: cell, state: state)
      cell.contentConfiguration = Self.content(
        row, state: state, isSidebar: isSidebar, environment: environment, select: select)
      cell.contentView.alpha = Self.leavesPlaceholder(row, state: state) ? 0 : 1
    }
    cell.setNeedsUpdateConfiguration()
  }

  private static func content(
    _ row: Row, state: UICellConfigurationState, isSidebar: Bool, environment: EnvironmentValues,
    select: @escaping (UUID) -> Void
  ) -> UIContentConfiguration {
    let content = HomeSidebarCollectionCellContent(
      row: row, environment: environment, isSelected: state.isSelected, isSidebar: isSidebar, select: select)
    let margins = row.margins ?? (isSidebar ? sidebarRowMargins : nil)
    guard let margins else { return UIHostingConfiguration { content } }
    return UIHostingConfiguration { content }.margins(.all, margins)
  }

  private static func leavesPlaceholder(_ row: Row, state: UICellConfigurationState) -> Bool {
    row.draggedSection != nil && state.cellDragState == .dragging
  }

  private static let sidebarRowMargins = EdgeInsets(top: 15, leading: 20, bottom: 15, trailing: 20)

  private static func background(
    _ row: Row, cell: UICollectionViewListCell, state: UICellConfigurationState
  )
    -> UIBackgroundConfiguration
  {
    switch row.background {
    case .system: cell.defaultBackgroundConfiguration().updated(for: state)
    case .clear: .clear()
    case let .card(edges): HomeSidebarCardBackground.configuration(edges: edges, isHighlighted: state.isHighlighted)
    }
  }
}
