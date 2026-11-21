import SwiftUI
import UIKit

enum HomeSidebarCollectionLayout {
  typealias Row = HomeSidebarCollectionRow

  static func make(for controller: HomeSidebarCollectionController) -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { [weak controller] index, environment in
      let section = controller?.section(at: index) ?? .outline
      let configuration = listConfiguration(
        for: section, appearance: controller?.currentAppearance ?? .plain, controller: controller)
      let appearance = controller?.currentAppearance ?? .plain
      let layout = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
      if appearance == .sidebar { layout.contentInsets = sidebarInsets(for: section, from: layout.contentInsets) }
      return layout
    }
  }

  private static func listConfiguration(
    for section: Row.Section, appearance: HomeSidebarCollection.Appearance,
    controller: HomeSidebarCollectionController?
  ) -> UICollectionLayoutListConfiguration {
    var configuration = UICollectionLayoutListConfiguration(appearance: appearance.isConversation ? .plain : .sidebar)
    configuration.backgroundColor = HomeSidebarHeaderMetrics.listBackground(isConversation: appearance.isConversation)
    configuration.showsSeparators = true
    configuration.headerMode = headerMode(for: section, appearance: appearance)
    configuration.itemSeparatorHandler = { [weak controller] indexPath, separators in
      guard let row = controller?.row(at: indexPath) else { return separators }
      return hiding(row.hiddenSeparators, isFirst: indexPath.item == 0, in: separators)
    }
    return configuration
  }

  private static let sidebarListTopInset: CGFloat = 28

  private static func sidebarInsets(
    for section: Row.Section, from insets: NSDirectionalEdgeInsets
  )
    -> NSDirectionalEdgeInsets
  {
    var insets = insets
    switch section {
    case .outline:
      insets.top += sidebarListTopInset
      insets.bottom = 0
    case .archived:
      insets.top = 0
    }
    return insets
  }

  private static func headerMode(
    for section: Row.Section, appearance: HomeSidebarCollection.Appearance
  ) -> UICollectionLayoutListConfiguration.HeaderMode {
    section == .archived && appearance.isConversation ? .supplementary : .none
  }

  private static func hiding(
    _ edges: VerticalEdge.Set, isFirst: Bool, in separators: UIListSeparatorConfiguration
  ) -> UIListSeparatorConfiguration {
    var separators = separators
    if edges.contains(.top) || isFirst { separators.topSeparatorVisibility = .hidden }
    if edges.contains(.bottom) { separators.bottomSeparatorVisibility = .hidden }
    return separators
  }
}
