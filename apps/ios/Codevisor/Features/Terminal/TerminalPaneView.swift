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

  /// As on macOS: the system theme puts the terminal on the same surface as
  /// the chat, with label-colored text; a theme brings its own palette.
  private var colors: TerminalColors {
    TerminalColors(palette: theme.palette?.terminal, colorScheme: colorScheme)
  }

  private var isRegularWidth: Bool { horizontalSizeClass == .regular }

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
        // Compact width runs under the home indicator while the keyboard is
        // down. Beside a sidebar the pane's bottom inset also carries the
        // keyboard, which the terminal must stay above; the background still
        // fills the strip below.
        .ignoresSafeArea(
          .container, edges: isRegularWidth || keyController.keyboardVisible ? [] : .bottom
        )
        // The key bar takes its own rows rather than covering the prompt or
        // a full-screen app's status line.
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if keyController.keyboardVisible {
            TerminalKeyBar(controller: keyController)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
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
    .animation(.snappy(duration: 0.25), value: keyController.keyboardVisible)
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
    let container = UIView()
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
    session.view.frame = container.bounds
    session.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(session.view)
  }

  func makeCoordinator() -> TerminalSession { session }

  static func dismantleUIView(_ container: UIView, coordinator session: TerminalSession) {
    // The session stays connected (see TerminalSessionCache). A newer
    // container may already have adopted its view.
    if session.view.superview === container { session.view.removeFromSuperview() }
    TerminalSessionCache.shared.didHide(session)
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
