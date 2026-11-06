import CodevisorCoreMac
import CodevisorUI
import SwiftUI
import TranscriptKit

struct PluginAppPiPCard: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let app: PluginAppInlineModel
  @Binding var corner: ComputerUseLivePreviewCorner
  @Binding var width: CGFloat?
  let container: CGSize
  let insets: ComputerUseLivePreviewInsets
  let coordinateSpace: String
  @State private var isHovering = false
  @State private var dragOffset: CGSize = .zero
  @State private var liveWidth: CGFloat?
  @State private var resizeStartWidth: CGFloat?

  var body: some View {
    let size = PluginAppPiPLayout.size(
      width: liveWidth ?? width, contentHeight: app.page.height, container: container, insets: insets)
    let origin = ComputerUseLivePreviewLayout.origin(
      corner: corner, cardSize: size, container: container, insets: insets)
    let shape = RoundedRectangle(cornerRadius: ComputerUseLivePreviewLayout.fallbackCornerRadius, style: .continuous)
    PluginAppPageView(page: app.page, onRetry: app.retry)
      .frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor))
      .clipShape(shape)
      .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
      .overlay { PluginAppPiPResizeEdges(size: size, coordinateSpace: coordinateSpace, resize: resize, settle: settle) }
      .overlay(alignment: .top) { grabber(size: size, origin: origin) }
      .overlay(alignment: .topLeading) {
        LivePreviewPiPCloseButton(
          help: "Show in Chat", label: "Show \(app.app.serverName) in the chat", isHovering: isHovering
        ) { app.request(.inline) }
      }
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(app.app.serverName) in picture in picture")
      .offset(x: origin.x + dragOffset.width, y: origin.y + dragOffset.height)
      .onChange(of: colorScheme, initial: true) { _, _ in showPage() }
  }

  private var snapAnimation: Animation? {
    reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2)
  }

  private func grabber(size: CGSize, origin: CGPoint) -> some View {
    Capsule()
      .fill(.secondary)
      .frame(width: 36, height: 5)
      .frame(width: max(0, size.width - 96), height: Self.grabberHeight)
      .contentShape(Rectangle())
      .opacity(isHovering ? 1 : 0)
      .allowsHitTesting(isHovering)
      .pointerStyle(.grabIdle)
      .gesture(drag(size: size, origin: origin))
      .contextMenu {
        PluginAppPiPMenu(app: app, corner: $corner, canResetSize: width != nil) {
          withAnimation(snapAnimation) { width = nil }
        }
      }
      .help("Drag to move")
  }

  private static var grabberHeight: CGFloat { 22 }

  private func drag(size: CGSize, origin: CGPoint) -> some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinateSpace))
      .onChanged { value in dragOffset = value.translation }
      .onEnded { value in
        let center = CGPoint(
          x: origin.x + size.width / 2 + value.predictedEndTranslation.width,
          y: origin.y + size.height / 2 + value.predictedEndTranslation.height)
        let snapped = ComputerUseLivePreviewLayout.corner(projectedCenter: center, container: container, insets: insets)
        withAnimation(snapAnimation) {
          corner = snapped
          dragOffset = .zero
        }
      }
  }

  private func resize(_ handle: ComputerUseLivePreviewResizeHandle, _ translation: CGFloat, _ current: CGFloat) {
    let start = resizeStartWidth ?? current
    resizeStartWidth = start
    liveWidth = PluginAppPiPLayout.resizedWidth(handle: handle, startWidth: start, translation: translation)
  }

  private func settle() {
    if let liveWidth { width = liveWidth }
    liveWidth = nil
    resizeStartWidth = nil
  }

  private func showPage() {
    app.show(
      display: PluginAppDisplay(
        isDark: colorScheme == .dark, platform: PluginAppDisplay.currentPlatform,
        locale: PluginAppDisplay.currentLocale))
  }
}

private struct PluginAppPiPResizeEdges: View {
  let size: CGSize
  let coordinateSpace: String
  let resize: (ComputerUseLivePreviewResizeHandle, CGFloat, CGFloat) -> Void
  let settle: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      edge(.leading)
      Spacer(minLength: 0)
      edge(.trailing)
    }
    .frame(width: size.width, height: size.height)
  }

  private func edge(_ handle: ComputerUseLivePreviewResizeHandle) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .frame(width: 6)
      .pointerStyle(.frameResize(position: handle == .leading ? .leading : .trailing))
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
          .onChanged { value in resize(handle, value.translation.width, size.width) }
          .onEnded { _ in settle() }
      )
      .accessibilityHidden(true)
  }
}

private struct PluginAppPiPMenu: View {
  let app: PluginAppInlineModel
  @Binding var corner: ComputerUseLivePreviewCorner
  let canResetSize: Bool
  let resetSize: () -> Void

  var body: some View {
    Button("Show in Chat", systemImage: "rectangle.inset.filled.and.person.filled") { app.request(.inline) }
    if app.canPresent(.fullscreen) {
      Button(
        app.fullscreen == .tab ? "Open in Tab" : "Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right"
      ) {
        app.request(.fullscreen)
      }
    }
    Button("Refresh", systemImage: "arrow.clockwise", action: app.retry)
    Divider()
    Picker("Move to", systemImage: "arrow.up.and.down.and.arrow.left.and.right", selection: $corner) {
      ForEach(ComputerUseLivePreviewCorner.allCases, id: \.self) { corner in
        Text(corner.title).tag(corner)
      }
    }
    .pickerStyle(.menu)
    Button("Reset Size", systemImage: "arrow.down.right.and.arrow.up.left", action: resetSize)
      .disabled(!canResetSize)
  }
}
