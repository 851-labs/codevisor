import SwiftUI
import UIKit

/// One action in a group header's menu.
struct HomeGroupHeaderAction {
  let title: String
  let systemImage: String
  var isDestructive = false
  let perform: () -> Void
}

/// A group header's menu, opened on request rather than by a touch of its
/// own: the header's long press belongs to reordering, so the menu opens
/// when that press lets go without moving. It's the system's pull-down
/// menu, anchored to the header behind which this sits.
struct HomeGroupMenuAnchor: UIViewRepresentable {
  let menu: [HomeGroupHeaderAction]
  /// Changes each time the menu should open; nil when it shouldn't.
  let request: Int?

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .custom)
    button.showsMenuAsPrimaryAction = true
    // Touches go to the header in front; only a request opens the menu.
    button.isUserInteractionEnabled = false
    button.isAccessibilityElement = false
    return button
  }

  func updateUIView(_ button: UIButton, context: Context) {
    button.menu = UIMenu(
      children: menu.map { action in
        UIAction(
          title: action.title, image: UIImage(systemName: action.systemImage),
          attributes: action.isDestructive ? .destructive : []
        ) { _ in action.perform() }
      })
    guard let request, request != context.coordinator.lastRequest else { return }
    context.coordinator.lastRequest = request
    button.performPrimaryAction()
  }

  @MainActor
  final class Coordinator {
    var lastRequest: Int?
  }
}
