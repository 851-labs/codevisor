//  The floating card over a chat that shows what its agent is controlling.

import AppKit
import CodevisorCoreMac
import SwiftUI

struct ComputerUsePiPOverlay: View {
  static let maxWidth: CGFloat = 320
  static let maxHeight: CGFloat = 260

  @State private var model: ComputerUsePiPModel
  @State private var isHovering = false
  private let isTurnRunning: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(chatSessionID: UUID, source: ComputerUsePiPModel.Source, isTurnRunning: Bool) {
    _model = State(initialValue: ComputerUsePiPModel(chatSessionID: chatSessionID, source: source))
    self.isTurnRunning = isTurnRunning
  }

  var body: some View {
    ZStack {
      if model.isVisible, let viewer = model.viewer {
        card(viewer: viewer)
          .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .spring(duration: 0.3), value: model.isVisible)
    .onAppear {
      model.turnActivityChanged(isRunning: isTurnRunning)
      model.sync()
    }
    .onChange(of: model.activity) { model.sync() }
    .onChange(of: isTurnRunning) { _, running in model.turnActivityChanged(isRunning: running) }
    .onDisappear { model.teardown() }
  }

  private func card(viewer: ComputerUseLivePreviewViewer) -> some View {
    let size = computerUseLivePreviewSize(
      frameSize: viewer.frameSize ?? .zero,
      maxWidth: Self.maxWidth,
      maxHeight: Self.maxHeight
    )
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return ZStack(alignment: .topLeading) {
      ComputerUsePiPSurface(viewer: viewer)
        .opacity(model.isLive ? 1 : 0.55)
      if let cursor = model.cursor {
        ComputerUsePiPCursor(tint: model.tint)
          .position(x: cursor.x * size.width, y: cursor.y * size.height)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: cursor)
          .allowsHitTesting(false)
      }
      if let status = model.statusText {
        Text(status)
          .font(.caption.weight(.medium))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .glassEffect(.regular, in: .capsule)
          .padding(12)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .allowsHitTesting(false)
      }
      // Native PiP's control: hidden until hover, then a glass close button.
      closeButton
        .padding(8)
        .opacity(isHovering ? 1 : 0)
        .scaleEffect(isHovering ? 1 : 0.9)
        .allowsHitTesting(isHovering)
    }
    .frame(width: size.width, height: size.height)
    .background(.black)
    .clipShape(shape)
    .overlay {
      shape.strokeBorder(model.tint.opacity(model.isLive ? 0.9 : 0.3), lineWidth: 1.5)
    }
    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    .contentShape(shape)
    .onHover { isHovering = $0 }
    .onTapGesture { model.activateTarget() }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
    .help(model.canActivateTarget ? "Show \(model.title)" : model.title)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Live view of \(model.title) controlled by the agent")
  }

  private var closeButton: some View {
    Button {
      model.dismiss()
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 28, height: 28)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .glassEffect(.regular.interactive(), in: .circle)
    .help("Close live view")
    .accessibilityLabel("Close live view of \(model.title)")
  }
}

/// Hosts the viewer's stable container; the viewer is detached by its model.
private struct ComputerUsePiPSurface: NSViewRepresentable {
  let viewer: ComputerUseLivePreviewViewer

  func makeNSView(context: Context) -> NSView {
    viewer.setBackgroundColor(.black)
    return viewer.view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

/// The agent's pointer, drawn in its session colour.
private struct ComputerUsePiPCursor: View {
  let tint: Color

  var body: some View {
    ComputerUsePiPArrow()
      .fill(tint)
      .overlay(ComputerUsePiPArrow().stroke(.white, lineWidth: 1.2))
      .frame(width: 12, height: 16)
      .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
      // Anchor the arrow's tip, not its centre, at the position.
      .offset(x: 6, y: 8)
  }
}

private struct ComputerUsePiPArrow: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.85))
    path.addLine(to: CGPoint(x: rect.width * 0.32, y: rect.height * 0.65))
    path.addLine(to: CGPoint(x: rect.width * 0.55, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.width * 0.72, y: rect.height * 0.92))
    path.addLine(to: CGPoint(x: rect.width * 0.5, y: rect.height * 0.6))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.6))
    path.closeSubpath()
    return path
  }
}
