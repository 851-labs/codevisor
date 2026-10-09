import SwiftUI
import UIKit

/// One action in a group header's long-press menu.
struct HomeGroupHeaderAction {
  let title: String
  let systemImage: String
  var isDestructive = false
  let perform: () -> Void
}

/// A group's header with UIKit's context menu and drag on it, which
/// `List` section headers don't get from SwiftUI. Together they behave as a
/// list row does: a long press shows the menu (when there is one), and
/// moving the finger lifts the header out of it into a drag. The drag
/// reports where it is in window space, which is SwiftUI's global space here,
/// and when it ends.
struct HomeGroupHeaderHost<Content: View>: UIViewRepresentable {
  let title: String
  let content: Content
  let menu: [HomeGroupHeaderAction]
  let onBegin: () -> Void
  let onMove: (CGFloat) -> Void
  let onEnd: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UIView {
    let hosted = UIHostingConfiguration { content }.margins(.all, 0).makeContentView()
    hosted.backgroundColor = .clear
    context.coordinator.hosted = hosted
    let container = UIView()
    container.backgroundColor = .clear
    hosted.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(hosted)
    NSLayoutConstraint.activate([
      hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      hosted.topAnchor.constraint(equalTo: container.topAnchor),
      hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    container.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
    let drag = UIDragInteraction(delegate: context.coordinator)
    drag.isEnabled = true
    container.addInteraction(drag)
    return container
  }

  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.hosted?.configuration = UIHostingConfiguration { content }.margins(.all, 0)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
    let width = proposal.width ?? uiView.bounds.width
    let size = context.coordinator.hosted?.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    return size.map { CGSize(width: width, height: $0.height) }
  }

  @MainActor
  final class Coordinator: NSObject, UIContextMenuInteractionDelegate, UIDragInteractionDelegate {
    var parent: HomeGroupHeaderHost?
    var hosted: (UIView & UIContentView)?

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard let actions = parent?.menu, !actions.isEmpty else { return nil }
      return UIContextMenuConfiguration(actionProvider: { _ in
        UIMenu(
          children: actions.map { action in
            UIAction(
              title: action.title, image: UIImage(systemName: action.systemImage),
              attributes: action.isDestructive ? .destructive : []
            ) { _ in action.perform() }
          })
      })
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
      // The list is the only place it lands.
      let item = UIDragItem(itemProvider: NSItemProvider())
      // Under the finger, the group is its name: a header-wide preview
      // would hang off the screen's edge.
      let title = parent?.title ?? ""
      item.previewProvider = { UIDragPreview(view: Self.pill(title)) }
      return [item]
    }

    private static func pill(_ title: String) -> UIView {
      let label = UILabel()
      label.text = title
      label.font = .preferredFont(forTextStyle: .headline)
      label.textColor = .label
      let size = label.intrinsicContentSize
      let pill = UIView(frame: CGRect(x: 0, y: 0, width: size.width + 32, height: size.height + 20))
      pill.backgroundColor = .secondarySystemGroupedBackground
      pill.layer.cornerRadius = pill.bounds.height / 2
      pill.layer.cornerCurve = .continuous
      label.frame = pill.bounds.insetBy(dx: 16, dy: 10)
      pill.addSubview(label)
      return pill
    }

    func dragInteraction(
      _ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession
    )
      -> Bool
    { true }

    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: UIDragSession) {
      parent?.onBegin()
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionDidMove session: UIDragSession) {
      guard let window = interaction.view?.window else { return }
      parent?.onMove(session.location(in: window).y)
    }

    func dragInteraction(
      _ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation
    ) {
      parent?.onEnd()
    }
  }
}
