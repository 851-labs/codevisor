import SwiftUI

struct WorkspaceInspectorTabBar: View {
  @Binding var selection: WorkspaceInspectorTab

  @State private var frames: [WorkspaceInspectorTab: CGRect] = [:]
  @State private var indicator = CGRect.zero
  @State private var isMoving = false
  @GestureState private var isPressed = false

  private static let space = "WorkspaceInspectorTabBar"

  var body: some View {
    ZStack(alignment: .topLeading) {
      Capsule()
        .fill(Color.accentColor.opacity(isPressed || isMoving ? 1 : 0.62))
        .overlay {
          Capsule()
            .strokeBorder(
              LinearGradient(
                colors: [.white.opacity(0.38), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
              lineWidth: 0.75
            )
        }
        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
        .frame(width: indicator.width, height: indicator.height)
        .offset(x: indicator.minX, y: indicator.minY)
        .opacity(indicator.isEmpty ? 0 : 1)
      labels(highlighted: false)
      labels(highlighted: true)
        .mask(alignment: .topLeading) {
          Capsule()
            .frame(width: indicator.width, height: indicator.height)
            .offset(x: indicator.minX, y: indicator.minY)
        }
        .allowsHitTesting(false)
    }
    .coordinateSpace(.named(Self.space))
    .fixedSize()
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
        .updating($isPressed) { _, pressed, _ in pressed = true }
        .onEnded { value in
          guard let tab = frames.first(where: { $0.value.contains(value.location) })?.key else { return }
          selection = tab
        }
    )
    .onChange(of: selection) { _, tab in move(to: tab) }
    .accessibilityRepresentation {
      Picker("Inspector Section", selection: $selection) {
        ForEach(WorkspaceInspectorTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  private func labels(highlighted: Bool) -> some View {
    HStack(spacing: 0) {
      ForEach(WorkspaceInspectorTab.allCases) { tab in
        Text(tab.title)
          .font(.system(size: 11, weight: highlighted ? .semibold : .regular))
          .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
          .fixedSize()
          .frame(width: highlighted ? frames[tab]?.width : nil, height: highlighted ? frames[tab]?.height : nil)
          .padding(.horizontal, highlighted ? 0 : 10)
          .padding(.vertical, highlighted ? 0 : 6.5)
          .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.space))
          } action: { frame in
            guard !highlighted else { return }
            frames[tab] = frame
            if tab == selection && !isMoving { indicator = frame }
          }
      }
    }
  }

  private func move(to tab: WorkspaceInspectorTab) {
    guard let target = frames[tab] else { return }
    isMoving = true
    withAnimation(.smooth(duration: 0.28)) {
      indicator = target
    } completion: {
      withAnimation(.easeOut(duration: 0.15)) { isMoving = false }
    }
  }
}
