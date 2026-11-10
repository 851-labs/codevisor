import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

struct FloatingPaneCard: View {
  let group: PaneGroupModel
  let title: String
  let frame: CGRect
  let container: CGSize
  let coordinateSpace: String
  let actions: FloatingPaneActions

  @State private var liveFrame: CGRect?
  @State private var resizeStart: CGRect?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let shape = RoundedRectangle(
    cornerRadius: ComputerUseLivePreviewLayout.fallbackCornerRadius, style: .continuous)

  var body: some View {
    let shown = liveFrame ?? frame
    VStack(spacing: 0) {
      FloatingPaneHeader(
        pane: group.state.selectedPane,
        title: title,
        source: PaneToolbarSource(group: group),
        coordinateSpace: coordinateSpace,
        actions: actions,
        drag: drag
      )
      PaneGroupContent(group: group)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background { PaneActivationObserver(onActivate: actions.activate, isFloating: true) }
    .frame(width: shown.width, height: shown.height)
    .background(Color.windowBackgroundColor)
    .clipShape(Self.shape)
    .overlay { Self.shape.strokeBorder(Color.separatorColor) }
    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    .overlay(alignment: .topLeading) { resizeHandles(size: shown.size) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Floating \(title)")
    .offset(x: shown.minX, y: shown.minY)
  }

  private var drag: FloatingPaneDrag {
    FloatingPaneDrag(
      changed: { translation in
        liveFrame = FloatingPaneGeometry.moved(frame, by: translation, container: container)
      },
      ended: {
        commit(FloatingPaneGeometry.snapped(liveFrame ?? frame, container: container))
      }
    )
  }

  private func resizeHandles(size: CGSize) -> some View {
    PiPResizeHandles(
      size: size,
      coordinateSpace: coordinateSpace,
      onChanged: { handle, translation in
        let start = resizeStart ?? frame
        resizeStart = start
        liveFrame = FloatingPaneGeometry.resized(start, handle: handle, translation: translation, container: container)
      },
      onEnded: {
        resizeStart = nil
        commit(liveFrame ?? frame)
      }
    )
  }

  private func commit(_ committed: CGRect) {
    withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2)) {
      actions.move(committed)
      liveFrame = nil
    }
  }
}
