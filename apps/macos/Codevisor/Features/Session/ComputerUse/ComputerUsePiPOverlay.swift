import AppKit
import CodevisorCoreMac
import SwiftUI

struct ComputerUsePiPOverlay<Model: LivePreviewPiPModel>: View {
  @State private var model: Model
  @State private var isHovering = false
  @State private var dragOffset: CGSize = .zero
  @State private var liveArea: CGFloat?
  @State private var resizeStartSize: CGSize?
  @Environment(\.displayScale) private var displayScale
  private let isTurnRunning: Bool
  private let composerHeight: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static var coordinateSpace: String { "computer-use-pip-pane" }

  init(model: @autoclosure () -> Model, isTurnRunning: Bool, composerHeight: CGFloat) {
    _model = State(wrappedValue: model())
    self.isTurnRunning = isTurnRunning
    self.composerHeight = composerHeight
  }

  var body: some View {
    GeometryReader { geometry in
      let insets = ComputerUseLivePreviewLayout.insets(composerHeight: composerHeight)
      ZStack(alignment: .topLeading) {
        Color.clear.allowsHitTesting(false)
        if model.isVisible, let viewer = model.viewer {
          let aspect = aspect(viewer: viewer)
          let size = cardSize(aspect: aspect, container: geometry.size, insets: insets)
          let origin = ComputerUseLivePreviewLayout.origin(
            corner: model.corner, cardSize: size, container: geometry.size, insets: insets)
          card(viewer: viewer, size: size, resizeHandles: resizeHandles(size: size, aspect: aspect, viewer: viewer))
            .gesture(dragGesture(cardSize: size, origin: origin, container: geometry.size, insets: insets))
            .overlay(alignment: .topLeading) { closeControl }
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Live view of \(model.title) controlled by the agent")
            .accessibilityAction(.default) { model.activateTarget() }
            .id(ObjectIdentifier(viewer))
            .offset(x: origin.x + dragOffset.width, y: origin.y + dragOffset.height)
            .transition(.scale(scale: 0.92, anchor: model.corner.unitPoint).combined(with: .opacity))
        }
      }
      .coordinateSpace(name: Self.coordinateSpace)
      .animation(reduceMotion ? nil : .spring(duration: 0.3), value: composerHeight)
    }
    .animation(reduceMotion ? nil : .spring(duration: 0.3), value: model.isVisible)
    .onAppear { model.appeared(isTurnRunning: isTurnRunning) }
    .onChange(of: model.changeKey) { model.sync() }
    .onChange(of: isTurnRunning) { _, running in model.turnActivityChanged(isRunning: running) }
    .onDisappear { model.teardown() }
  }

  private func aspect(viewer: ComputerUseLivePreviewViewer) -> CGFloat {
    guard let frame = viewer.frameSize, frame.width > 0, frame.height > 0 else { return 16.0 / 10.0 }
    let content = viewer.windowContent?.rect.size ?? CGSize(width: 1, height: 1)
    guard content.width > 0, content.height > 0 else { return frame.width / frame.height }
    return (frame.width * content.width) / (frame.height * content.height)
  }

  private func cardSize(
    aspect: CGFloat,
    container: CGSize,
    insets: ComputerUseLivePreviewInsets
  ) -> CGSize {
    ComputerUseLivePreviewLayout.size(
      area: liveArea ?? model.area ?? ComputerUseLivePreviewLayout.defaultArea(aspect: aspect),
      aspect: aspect,
      container: container,
      insets: insets
    )
  }

  private func resizeHandles(
    size: CGSize,
    aspect: CGFloat,
    viewer: ComputerUseLivePreviewViewer
  ) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(ComputerUseLivePreviewResizeHandle.allCases, id: \.self) { handle in
        let zone = handle.zone(in: size)
        Color.clear
          .contentShape(Rectangle())
          .frame(width: zone.width, height: zone.height)
          .offset(x: zone.minX, y: zone.minY)
          .pointerStyle(.frameResize(position: handle.framePosition))
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpace))
              .onChanged { value in
                let start = resizeStartSize ?? size
                resizeStartSize = start
                liveArea = ComputerUseLivePreviewLayout.resizedArea(
                  handle: handle, startSize: start, translation: value.translation, aspect: aspect)
              }
              .onEnded { _ in
                if let liveArea { model.area = liveArea }
                liveArea = nil
                resizeStartSize = nil
              }
          )
          .accessibilityHidden(true)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .onChange(of: resizeStartSize == nil ? size : nil) { _, settled in
      if let settled { viewer.setDisplaySize(settled, backingScale: displayScale) }
    }
    .onAppear { viewer.setDisplaySize(size, backingScale: displayScale) }
  }

  private func dragGesture(
    cardSize: CGSize,
    origin: CGPoint,
    container: CGSize,
    insets: ComputerUseLivePreviewInsets
  ) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.coordinateSpace))
      .onChanged { value in
        dragOffset = value.translation
      }
      .onEnded { value in
        let projectedCenter = CGPoint(
          x: origin.x + cardSize.width / 2 + value.predictedEndTranslation.width,
          y: origin.y + cardSize.height / 2 + value.predictedEndTranslation.height
        )
        let corner = ComputerUseLivePreviewLayout.corner(
          projectedCenter: projectedCenter, container: container, insets: insets)
        withAnimation(snapAnimation) {
          model.corner = corner
          dragOffset = .zero
        }
      }
  }

  private var snapAnimation: Animation? {
    reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2)
  }

  private var contextMenu: some View {
    let model = model
    let snap = snapAnimation
    return ComputerUsePiPContextMenu(
      title: model.title,
      showsTarget: model.showsTarget,
      canActivateTarget: model.canActivateTarget,
      canReload: model.canReload,
      corner: model.corner,
      hasCustomSize: model.hasCustomSize,
      actions: .init(
        activateTarget: { model.activateTarget() },
        reload: { model.reload() },
        move: { corner in withAnimation(snap) { model.corner = corner } },
        resetSize: { withAnimation(snap) { model.resetSize() } },
        close: { model.dismiss() }
      )
    )
    .equatable()
  }

  private func cursorScale(cardWidth: CGFloat) -> CGFloat {
    ComputerUseLivePreviewLayout.cursorScale(
      cardWidth: cardWidth, windowWidth: model.cursorWindowWidth)
  }

  private func card(
    viewer: ComputerUseLivePreviewViewer,
    size: CGSize,
    resizeHandles: some View
  ) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: ComputerUseLivePreviewLayout.cardCornerRadius(
        radiusFraction: viewer.windowContent?.cornerRadiusFraction, cardSize: size),
      style: .continuous
    )
    let surface = ComputerUseLivePreviewLayout.surfaceFrame(
      frameSize: viewer.frameSize, content: viewer.windowContent?.rect, cardSize: size)
    return ZStack(alignment: .topLeading) {
      ComputerUsePiPSurface(viewer: viewer)
        .frame(width: surface.width, height: surface.height)
        .offset(x: surface.minX, y: surface.minY)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(model.isLive ? 1 : 0.55)
      if let cursor = model.cursor {
        ComputerUseCursorGlyph(tint: model.tint, scale: cursorScale(cardWidth: size.width))
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
    }
    .frame(width: size.width, height: size.height)
    .background(.black)
    .clipShape(shape)
    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    .contentShape(shape)
    .overlay(alignment: .topLeading) { resizeHandles }
    .onTapGesture { model.activateTarget() }
    .contextMenu { contextMenu }
    .help(model.canActivateTarget ? "Show \(model.title)" : model.title)
  }

  private var closeControl: some View {
    closeButton
      .padding(8)
      .opacity(isHovering ? 1 : 0)
      .scaleEffect(isHovering ? 1 : 0.9)
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

private struct ComputerUsePiPSurface: NSViewRepresentable {
  let viewer: ComputerUseLivePreviewViewer

  func makeNSView(context: Context) -> NSView {
    viewer.setBackgroundColor(.black)
    return viewer.view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

extension ComputerUseLivePreviewCorner {
  fileprivate var title: String {
    switch self {
    case .topLeading: "Top Left"
    case .topTrailing: "Top Right"
    case .bottomLeading: "Bottom Left"
    case .bottomTrailing: "Bottom Right"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .topLeading: "rectangle.inset.topleft.filled"
    case .topTrailing: "rectangle.inset.topright.filled"
    case .bottomLeading: "rectangle.inset.bottomleft.filled"
    case .bottomTrailing: "rectangle.inset.bottomright.filled"
    }
  }

  fileprivate var unitPoint: UnitPoint {
    switch self {
    case .topLeading: .topLeading
    case .topTrailing: .topTrailing
    case .bottomLeading: .bottomLeading
    case .bottomTrailing: .bottomTrailing
    }
  }
}

extension ComputerUseLivePreviewResizeHandle {
  private static let edgeThickness: CGFloat = 6
  private static let cornerLength: CGFloat = 14

  fileprivate func zone(in size: CGSize) -> CGRect {
    let edge = Self.edgeThickness
    let corner = Self.cornerLength
    let horizontalEdge = max(0, size.width - corner * 2)
    let verticalEdge = max(0, size.height - corner * 2)
    switch self {
    case .top: return CGRect(x: corner, y: 0, width: horizontalEdge, height: edge)
    case .bottom: return CGRect(x: corner, y: size.height - edge, width: horizontalEdge, height: edge)
    case .leading: return CGRect(x: 0, y: corner, width: edge, height: verticalEdge)
    case .trailing: return CGRect(x: size.width - edge, y: corner, width: edge, height: verticalEdge)
    case .topLeading: return CGRect(x: 0, y: 0, width: corner, height: corner)
    case .topTrailing: return CGRect(x: size.width - corner, y: 0, width: corner, height: corner)
    case .bottomLeading: return CGRect(x: 0, y: size.height - corner, width: corner, height: corner)
    case .bottomTrailing:
      return CGRect(x: size.width - corner, y: size.height - corner, width: corner, height: corner)
    }
  }

  fileprivate var framePosition: FrameResizePosition {
    switch self {
    case .top: .top
    case .bottom: .bottom
    case .leading: .leading
    case .trailing: .trailing
    case .topLeading: .topLeading
    case .topTrailing: .topTrailing
    case .bottomLeading: .bottomLeading
    case .bottomTrailing: .bottomTrailing
    }
  }
}

private struct ComputerUsePiPContextMenu: View, Equatable {
  struct Actions {
    let activateTarget: @MainActor () -> Void
    let reload: @MainActor () -> Void
    let move: @MainActor (ComputerUseLivePreviewCorner) -> Void
    let resetSize: @MainActor () -> Void
    let close: @MainActor () -> Void
  }

  let title: String
  let showsTarget: Bool
  let canActivateTarget: Bool
  let canReload: Bool
  let corner: ComputerUseLivePreviewCorner
  let hasCustomSize: Bool
  let actions: Actions

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title && lhs.showsTarget == rhs.showsTarget
      && lhs.canActivateTarget == rhs.canActivateTarget && lhs.canReload == rhs.canReload
      && lhs.corner == rhs.corner && lhs.hasCustomSize == rhs.hasCustomSize
  }

  var body: some View {
    if showsTarget {
      Button(action: actions.activateTarget) { label("Show \(title)", "macwindow") }
        .disabled(!canActivateTarget)
    }
    Button(action: actions.reload) { label("Refresh", "arrow.clockwise") }
      .disabled(!canReload)
    Divider()
    Picker(selection: Binding(get: { corner }, set: actions.move)) {
      ForEach(ComputerUseLivePreviewCorner.allCases, id: \.self) { corner in
        label(corner.title, corner.systemImage).tag(corner)
      }
    } label: {
      label("Move to", "arrow.up.and.down.and.arrow.left.and.right")
    }
    .pickerStyle(.menu)
    Button(action: actions.resetSize) { label("Reset Size", "arrow.down.right.and.arrow.up.left") }
      .disabled(!hasCustomSize)
    Divider()
    Button(action: actions.close) { label("Close", "xmark") }
  }

  private func label(_ title: String, _ systemImage: String) -> some View {
    Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
  }
}
