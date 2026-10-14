import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI

struct TerminalPaneView: View {
  let terminalKey: String
  let cwd: String
  let config: CodevisorServerConfig

  @StateObject private var keyController = TerminalKeyController()
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.theme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @State private var paneBottom: CGFloat = 0
  @State private var keyBarTop: CGFloat?

  private var colors: TerminalColors {
    TerminalColors(palette: theme.palette?.terminal, colorScheme: colorScheme)
  }

  private var isRegularWidth: Bool { horizontalSizeClass == .regular }

  private var keyboardOverlap: CGFloat {
    guard let top = keyController.keyboardTop else { return 0 }
    return max(0, paneBottom - top)
  }

  private var session: TerminalSession {
    TerminalSessionCache.shared.session(
      terminalKey: terminalKey, cwd: cwd, config: config)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      let session = session
      TerminalHostView(
        session: session, keyController: keyController, colors: colors,
        coveredFrom: keyController.keyboardVisible ? keyBarTop : nil
      )
      .padding(.horizontal, 8)
      .ignoresSafeArea(.keyboard)
      .ignoresSafeArea(.container, edges: isRegularWidth ? [] : .bottom)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if keyController.keyboardVisible {
          TerminalKeyBar(controller: keyController)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) {
              $0.frame(in: .global).minY
            } action: {
              keyBarTop = $0
            }
            .padding(.bottom, keyboardOverlap)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }

      TerminalStatusBadge(session: session)

      if !keyController.keyboardVisible && !isRegularWidth {
        HStack {
          Spacer()
          ShowKeyboardButton { keyController.showKeyboard() }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 8)
        .transition(.opacity)
      }
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.frame(in: .global).maxY
    } action: {
      paneBottom = $0
    }
    .background(
      Color(uiColor: colors.background).ignoresSafeArea(
        .all, edges: isRegularWidth ? .vertical : .all)
    )
    .toolbar {
      if isRegularWidth {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            keyController.toggleKeyboard()
          } label: {
            Label(
              keyController.keyboardVisible ? "Hide Keyboard" : "Show Keyboard",
              systemImage: keyController.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
          }
        }
      }
    }
  }
}

private struct TerminalHostView: UIViewRepresentable {
  let session: TerminalSession
  let keyController: TerminalKeyController
  let colors: TerminalColors
  let coveredFrom: CGFloat?

  func makeUIView(context: Context) -> UIView {
    let container = TerminalContainerView()
    container.clipsToBounds = true
    adopt(into: container)
    return container
  }

  func updateUIView(_ container: UIView, context: Context) {
    adopt(into: container)
    if let container = container as? TerminalContainerView, container.coveredFrom != coveredFrom {
      container.coveredFrom = coveredFrom
      container.setNeedsLayout()
    }
  }

  private func adopt(into container: UIView) {
    session.apply(colors)
    keyController.attach(session.view)
    guard session.view.superview !== container else { return }
    for case let other as SessionTerminalView in container.subviews { other.removeFromSuperview() }
    container.addSubview(session.view)
    container.setNeedsLayout()
  }

  func makeCoordinator() -> TerminalSession { session }

  static func dismantleUIView(_ container: UIView, coordinator session: TerminalSession) {
    if session.view.superview === container {
      session.view.removeFromSuperview()
      session.hide()
    }
    TerminalSessionCache.shared.didHide(session)
  }
}

private final class TerminalContainerView: UIView, UIGestureRecognizerDelegate {
  var coveredFrom: CGFloat?
  private var visibleFrame: CGRect = .zero
  private var shownSize: CGSize = .zero
  private var fitScale: CGFloat = 1
  private var pinchStart: (zoom: CGFloat, offset: CGPoint)?
  private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
  private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
  private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))

  override init(frame: CGRect) {
    super.init(frame: frame)
    pan.maximumNumberOfTouches = 1
    tap.cancelsTouchesInView = false
    for recognizer in [pan, pinch, tap] as [UIGestureRecognizer] {
      recognizer.delegate = self
      addGestureRecognizer(recognizer)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  private var terminal: SessionTerminalView? {
    subviews.lazy.compactMap { $0 as? SessionTerminalView }.first
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    var frame = bounds
    if let coveredFrom {
      let covered = convert(CGPoint(x: 0, y: coveredFrom), from: nil).y
      frame.size.height = max(0, min(bounds.height, covered))
    }
    visibleFrame = frame
    guard let terminal else { return }
    guard let grid = terminal.foreignGrid?(frame.size) else {
      shownSize = frame.size
      place(terminal, size: frame.size, scale: 1, at: frame.origin, foreign: false)
      return
    }
    fitScale = min(frame.width / grid.width, frame.height / grid.height, 1)
    let scale = min(max(terminal.zoom, fitScale), 1)
    shownSize = CGSize(width: grid.width * scale, height: grid.height * scale)
    var offset = terminal.panOffset
    if let cursor = terminal.cursorToFollow() {
      offset = Self.offset(offset, revealing: cursor.applying(.init(scaleX: scale, y: scale)), in: frame.size)
    }
    offset.x = min(max(0, offset.x), max(0, shownSize.width - frame.width))
    offset.y = min(max(0, offset.y), max(0, shownSize.height - frame.height))
    terminal.panOffset = offset
    place(
      terminal, size: grid, scale: scale,
      at: CGPoint(x: frame.minX - offset.x, y: frame.minY - offset.y), foreign: true)
  }

  private static func offset(_ offset: CGPoint, revealing cursor: CGRect, in size: CGSize) -> CGPoint {
    var offset = offset
    let area = cursor.insetBy(dx: -cursor.width * 4, dy: -cursor.height)
    if area.maxX > offset.x + size.width { offset.x = area.maxX - size.width }
    if area.minX < offset.x { offset.x = area.minX }
    if area.maxY > offset.y + size.height { offset.y = area.maxY - size.height }
    if area.minY < offset.y { offset.y = area.minY }
    return offset
  }

  private func place(
    _ terminal: SessionTerminalView, size: CGSize, scale: CGFloat, at origin: CGPoint, foreign: Bool
  ) {
    terminal.showsForeignGrid = foreign
    let center = CGPoint(x: origin.x + size.width * scale / 2, y: origin.y + size.height * scale / 2)
    guard
      terminal.bounds.size != size || terminal.center != center || terminal.appliedScale != scale
    else { return }
    UIView.performWithoutAnimation {
      terminal.appliedScale = scale
      terminal.transform = .identity
      terminal.bounds = CGRect(origin: .zero, size: size)
      terminal.center = center
      terminal.transform = scale == 1 ? .identity : CGAffineTransform(scaleX: scale, y: scale)
      terminal.layoutIfNeeded()
    }
  }

  @objc private func panned(_ pan: UIPanGestureRecognizer) {
    guard let terminal else { return }
    let moved = pan.translation(in: self)
    pan.setTranslation(.zero, in: self)
    terminal.panOffset.x -= moved.x
    terminal.panOffset.y -= moved.y
    setNeedsLayout()
    layoutIfNeeded()
  }

  @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
    guard let terminal else { return }
    switch pinch.state {
    case .began:
      pinchStart = (terminal.appliedScale, terminal.panOffset)
    case .changed:
      guard let start = pinchStart, start.zoom > 0 else { return }
      let zoom = min(max(start.zoom * pinch.scale, fitScale), 1)
      let location = pinch.location(in: self)
      let anchor = CGPoint(x: location.x - visibleFrame.minX, y: location.y - visibleFrame.minY)
      terminal.zoom = zoom
      terminal.panOffset = CGPoint(
        x: (anchor.x + start.offset.x) / start.zoom * zoom - anchor.x,
        y: (anchor.y + start.offset.y) / start.zoom * zoom - anchor.y)
      setNeedsLayout()
      layoutIfNeeded()
    default:
      pinchStart = nil
    }
  }

  @objc private func tapped() {
    terminal?.onUse?()
  }

  override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    guard recognizer === pan || recognizer === pinch else {
      return super.gestureRecognizerShouldBegin(recognizer)
    }
    guard terminal?.showsForeignGrid == true else { return false }
    guard recognizer === pan else { return true }
    let velocity = pan.velocity(in: self)
    return abs(velocity.x) >= abs(velocity.y)
      ? shownSize.width > visibleFrame.width + 0.5
      : shownSize.height > visibleFrame.height + 0.5
  }

  func gestureRecognizer(
    _ recognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    recognizer === tap
  }

  func gestureRecognizer(
    _ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
  ) -> Bool {
    recognizer !== tap && other.view === terminal
      && (other is UIPanGestureRecognizer || other is UIPinchGestureRecognizer)
  }
}

private struct TerminalStatusBadge: View {
  @ObservedObject var session: TerminalSession

  var body: some View {
    if let status = session.status {
      Text(status)
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 60)
    }
  }
}
