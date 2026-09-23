import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftTerm
import SwiftUI

/// A terminal pane: the shell runs in the server's TerminalManager on the
/// paired machine (surviving disconnects with scrollback replay); this view is
/// a renderer speaking the shared TerminalTransport protocol. The terminal key
/// follows the shared pane scheme (`sessionId` for the first terminal,
/// `"<sessionUuid>:<paneUuid>"` for later panes), matching macOS. SwiftTerm is
/// the interim emulator surface — the GhosttyKit-for-iOS spike (plan Phase 7,
/// Track A) can replace the view without touching transport.
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
      TerminalHostView(session: session, keyController: keyController, colors: colors)
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
    if session.view.superview === container { session.view.removeFromSuperview() }
    TerminalSessionCache.shared.didHide(session)
  }
}

/// Hands the terminal its new size in one step instead of interpolating to
/// it. A terminal has no meaningful in-between size: with the size animated,
/// UIKit scales the last frame the terminal drew across the changing bounds
/// until it redraws — that was the text squashing and stretching while the
/// keyboard opened — and SwiftTerm recomputes its rows and signals the PTY on
/// every frame of the way. Taking the size at once costs one reflow and one
/// SIGWINCH; the chrome around the terminal still animates.
private final class TerminalContainerView: UIView {
  override func layoutSubviews() {
    super.layoutSubviews()
    for case let terminal as SessionTerminalView in subviews where terminal.frame != bounds {
      UIView.performWithoutAnimation {
        terminal.frame = bounds
        terminal.layoutIfNeeded()
      }
    }
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
