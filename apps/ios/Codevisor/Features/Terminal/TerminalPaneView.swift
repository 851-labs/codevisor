import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI

/// A terminal pane: the shell runs in the server's TerminalManager on the
/// paired machine (surviving disconnects with scrollback replay); this view is
/// a renderer speaking the shared TerminalTransport protocol. The terminal key
/// follows the shared pane scheme (`sessionId` for the first terminal,
/// `"<sessionUuid>:<paneUuid>"` for later panes), matching macOS. The
/// renderer is libghostty, as on macOS (see TerminalSession).
struct TerminalPaneView: View {
  let terminalKey: String
  let cwd: String
  let config: CodevisorServerConfig
  /// Attach to a terminal something else spawned (a harness auth flow's
  /// PTY) instead of asking the server to start a shell.
  var attachOnly: Bool = false

  @StateObject private var keyController = TerminalKeyController()
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.theme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  /// The pane's own bottom edge, in the space the key controller reports the
  /// keyboard's top edge in. Measured on the pane rather than on the
  /// terminal, which the inset below moves — that would feed back.
  @State private var paneBottom: CGFloat = 0
  /// Where the key bar's top edge sits (global coordinates) while it's up:
  /// the terminal ends there, so its prompt and last rows stay visible.
  @State private var keyBarTop: CGFloat?

  /// As on macOS: the system theme puts the terminal on the same surface as
  /// the chat, with label-colored text; a theme brings its own palette.
  private var colors: TerminalColors {
    TerminalColors(palette: theme.palette?.terminal, colorScheme: colorScheme)
  }

  private var isRegularWidth: Bool { horizontalSizeClass == .regular }

  /// How much of the pane the keyboard covers. The terminal is shrunk by
  /// exactly this much (plus the key bar), so its last rows stay readable
  /// instead of sitting under the keyboard.
  private var keyboardOverlap: CGFloat {
    guard let top = keyController.keyboardTop else { return 0 }
    return max(0, paneBottom - top)
  }

  /// Kept alive across visits, so returning shows the terminal as it is now.
  private var session: TerminalSession {
    TerminalSessionCache.shared.session(
      terminalKey: terminalKey, cwd: cwd, config: config, attachOnly: attachOnly)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      let session = session
      TerminalHostView(
        session: session, keyController: keyController, colors: colors,
        coveredFrom: keyController.keyboardVisible ? keyBarTop : nil
      )
      // Text keeps clear of the pane's edges: beside the sidebar and under
      // the window's resize corner it would otherwise touch them.
      .padding(.horizontal, 8)
      // The pane is already outside SwiftUI's keyboard avoidance beside a
      // sidebar (EdgeToEdgePaneHost); opt out in compact too, so the
      // keyboard reaches the terminal by exactly one route — the measured
      // inset below — and can't be counted twice.
      .ignoresSafeArea(.keyboard)
      // Compact width runs under the home indicator; beside a sidebar the
      // pane's own bottom inset keeps the text clear of it.
      .ignoresSafeArea(.container, edges: isRegularWidth ? [] : .bottom)
      // One inset carries both: the keyboard, and the key bar riding just
      // above it. The bar takes its own rows rather than covering the
      // prompt or a full-screen app's status line.
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

      // Beside a sidebar the keyboard toggle lives in the toolbar instead,
      // clear of the terminal's content.
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
    // Where the pane's bottom edge sits, to compare against the keyboard's
    // top edge. Nothing declares an animation for keyboardVisible here: the
    // key controller changes it inside the keyboard's own animation, so the
    // bar, the toggle and the inset all travel on the keyboard's curve
    // instead of racing a second one.
    .onGeometryChange(for: CGFloat.self) {
      $0.frame(in: .global).maxY
    } action: {
      paneBottom = $0
    }
    // Extend the surface under the keyboard too, so its rounded corners
    // don't reveal another color. Beside a sidebar (iPad) only up and
    // down: sideways it would run under the floating sidebar.
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

/// Hosts the session's terminal view, which outlives this pane: a later
/// visit adopts it into a new container.
private struct TerminalHostView: UIViewRepresentable {
  let session: TerminalSession
  let keyController: TerminalKeyController
  let colors: TerminalColors
  /// Where (global y) the key bar and keyboard start covering the pane. The
  /// terminal is laid out above it, so its prompt and last rows stay
  /// visible: the Ghostty view is a plain view that doesn't inset itself for
  /// the keyboard the way a scroll view-based terminal did.
  let coveredFrom: CGFloat?

  func makeUIView(context: Context) -> UIView {
    let container = TerminalContainerView()
    // The terminal takes its final size at once while the container is still
    // animating to it, so it must not draw outside it meanwhile.
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
    // Sized by the container's layoutSubviews rather than an autoresizing
    // mask, which would resize it inside whatever animation is running.
    container.addSubview(session.view)
    container.setNeedsLayout()
  }

  func makeCoordinator() -> TerminalSession { session }

  static func dismantleUIView(_ container: UIView, coordinator session: TerminalSession) {
    // The session stays connected (see TerminalSessionCache). A newer
    // container may already have adopted its view.
    if session.view.superview === container {
      session.view.removeFromSuperview()
      session.hide()
    }
    TerminalSessionCache.shared.didHide(session)
  }
}

/// Hands the terminal its new size in one step instead of interpolating to
/// it. A terminal has no meaningful in-between size: with the size animated,
/// UIKit scales the last frame the terminal drew across the changing bounds
/// until it redraws — that was the text squashing and stretching while the
/// keyboard opened — and the terminal recomputes its rows and signals the PTY
/// on every frame of the way. Taking the size at once costs one reflow and one
/// SIGWINCH; the chrome around the terminal still animates.
///
/// While another device owns the PTY at a size this one can't show, the
/// terminal is laid out at that device's grid and cropped to the screen at a
/// readable size: it follows the cursor, a drag pans it, and a pinch zooms
/// out to all of it. Tapping it makes this the device being used, and the
/// PTY takes this device's size.
private final class TerminalContainerView: UIView, UIGestureRecognizerDelegate {
  /// Global (window) y where the key bar and keyboard begin; nil when down.
  var coveredFrom: CGFloat?
  /// The part of the container the terminal shows in.
  private var visibleFrame: CGRect = .zero
  /// The terminal's on-screen size.
  private var shownSize: CGSize = .zero
  /// The scale that fits all of another device's grid on screen.
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

  /// The least pan that brings the cursor on screen, with some context
  /// around it.
  private static func offset(_ offset: CGPoint, revealing cursor: CGRect, in size: CGSize) -> CGPoint {
    var offset = offset
    let area = cursor.insetBy(dx: -cursor.width * 4, dy: -cursor.height)
    if area.maxX > offset.x + size.width { offset.x = area.maxX - size.width }
    if area.minX < offset.x { offset.x = area.minX }
    if area.maxY > offset.y + size.height { offset.y = area.maxY - size.height }
    if area.minY < offset.y { offset.y = area.minY }
    return offset
  }

  /// Lays the terminal out at `size`, scaled by `scale` from its top-left
  /// corner at `origin`.
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

  // MARK: - Gestures

  @objc private func panned(_ pan: UIPanGestureRecognizer) {
    guard let terminal else { return }
    let moved = pan.translation(in: self)
    pan.setTranslation(.zero, in: self)
    terminal.panOffset.x -= moved.x
    terminal.panOffset.y -= moved.y
    setNeedsLayout()
    layoutIfNeeded()
  }

  /// Zooms about the pinch, so what's under the fingers stays there.
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
    // Panning and pinching are for another device's grid; otherwise the
    // terminal's own scrolling and font zoom have them.
    guard terminal?.showsForeignGrid == true else { return false }
    guard recognizer === pan else { return true }
    // A drag the crop has no room for scrolls the terminal instead.
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

  /// The terminal's own scrolling and font zoom wait for these to decline.
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
