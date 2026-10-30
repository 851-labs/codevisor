import SwiftUI

struct WorkspaceInspectorTabBar: View {
  @Binding var selection: WorkspaceInspectorTab
  var tabs = WorkspaceInspectorTab.allCases
  var harnessId: String?
  var onTabFrames: (([WorkspaceInspectorTab: CGRect]) -> Void)?

  @State private var frames: [WorkspaceInspectorTab: CGRect] = [:]
  @State private var indicator = CGRect.zero
  @State private var isMoving = false
  @State private var moveGeneration = 0
  @GestureState private var isPressed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let scrollMargin: CGFloat = 10
  private static let space = "WorkspaceInspectorTabBar"

  var body: some View {
    ZStack(alignment: .topLeading) {
      Capsule()
        .fill(.white.opacity(isPressed || isMoving ? 0.12 : 0))
        .glassEffect(.regular, in: Capsule())
        .frame(width: indicator.width, height: indicator.height)
        .offset(x: indicator.minX, y: indicator.minY)
        .opacity(indicator.isEmpty ? 0 : 1)
      labels(highlighted: false)
        .mask(alignment: .topLeading) {
          Rectangle()
            .overlay(alignment: .topLeading) { indicatorShape.blendMode(.destinationOut) }
            .compositingGroup()
        }
      labels(highlighted: true)
        .mask(alignment: .topLeading) { indicatorShape }
        .allowsHitTesting(false)
    }
    .coordinateSpace(.named(Self.space))
    .fixedSize()
    .contentShape(Rectangle())
    .contentShape(.focusEffect, Capsule())
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .local)
        .updating($isPressed) { _, pressed, _ in pressed = true }
        .onChanged { value in
          guard let tab = frames.first(where: { $0.value.contains(value.location) })?.key, tab != selection else {
            return
          }
          selection = tab
        }
    )
    .focusable(interactions: .activate)
    .onKeyPress(.leftArrow) { step(-1) }
    .onKeyPress(.rightArrow) { step(1) }
    .onChange(of: selection) { _, tab in move(to: tab) }
    .onChange(of: tabs) { _, tabs in frames = frames.filter { tabs.contains($0.key) } }
    .onChange(of: frames, initial: true) { _, frames in onTabFrames?(frames) }
    .accessibilityRepresentation {
      Picker("Inspector Section", selection: $selection) {
        ForEach(tabs) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  private var indicatorShape: some View {
    Capsule()
      .frame(width: indicator.width, height: indicator.height)
      .offset(x: indicator.minX, y: indicator.minY)
  }

  private func labels(highlighted: Bool) -> some View {
    HStack(spacing: 0) {
      ForEach(tabs) { tab in
        label(for: tab, highlighted: highlighted)
          .foregroundStyle(highlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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

  private func label(for tab: WorkspaceInspectorTab, highlighted: Bool) -> some View {
    let weight: NSFont.Weight = highlighted ? .semibold : .regular
    return HStack(spacing: 4) {
      if tab == .harness {
        HarnessIcon(harnessId: harnessId ?? "", fallbackSymbolName: tab.systemImage, size: 10, weight: weight)
      } else {
        MenuSymbolIcon(systemName: tab.systemImage, size: 10, weight: weight)
      }
      Text(tab.title)
    }
    .font(.system(size: 11, weight: highlighted ? .semibold : .regular))
  }

  private func step(_ offset: Int) -> KeyPress.Result {
    guard let index = tabs.firstIndex(of: selection), tabs.indices.contains(index + offset) else {
      return .ignored
    }
    selection = tabs[index + offset]
    return .handled
  }

  private func move(to tab: WorkspaceInspectorTab) {
    guard let target = frames[tab] else { return }
    guard !reduceMotion else {
      indicator = target
      return
    }
    moveGeneration += 1
    let generation = moveGeneration
    isMoving = true
    withAnimation(.smooth(duration: 0.28)) {
      indicator = target
    } completion: {
      guard generation == moveGeneration else { return }
      if let settled = frames[selection], settled != indicator { indicator = settled }
      withAnimation(.easeOut(duration: 0.15)) { isMoving = false }
    }
  }
}
