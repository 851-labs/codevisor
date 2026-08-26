import CodevisorCore
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

    @State private var status: String?
    @StateObject private var keyController = TerminalKeyController()

    var body: some View {
        ZStack(alignment: .bottom) {
            TerminalHostView(
                terminalKey: terminalKey, cwd: cwd, config: config, attachOnly: attachOnly,
                keyController: keyController
            ) { status in
                self.status = status
            }
            .ignoresSafeArea(.container, edges: .bottom)

            if let status {
                Text(status)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 60)
            }

            if keyController.keyboardVisible {
                TerminalKeyBar(controller: keyController)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
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
        // Extend the black surface under the keyboard too — otherwise the
        // keyboard's rounded corners reveal the (light) window background.
        .background(Color.black.ignoresSafeArea(.all, edges: .all))
        // The terminal surface is always black; render the glass bar, keyboard
        // button, and status capsule in dark appearance to match.
        .environment(\.colorScheme, .dark)
    }
}

private struct TerminalHostView: UIViewRepresentable {
    let terminalKey: String
    let cwd: String
    let config: CodevisorServerConfig
    var attachOnly: Bool = false
    let keyController: TerminalKeyController
    let onStatus: (String?) -> Void

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.backgroundColor = .black
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        // The terminal is always black; keep the system keyboard dark to match
        // instead of following the device's light/dark appearance.
        view.keyboardAppearance = .dark
        // Drop SwiftTerm's built-in TerminalAccessory: the key bar is a SwiftUI
        // Liquid Glass overlay (TerminalKeyBar) floating over the content, so the
        // keyboard gets no accessory strip (and no system backdrop behind one).
        view.inputAccessoryView = nil
        // Swipe down over the terminal to dismiss the keyboard.
        view.keyboardDismissMode = .interactive
        keyController.attach(view)
        context.coordinator.attach(view: view)
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            terminalKey: terminalKey, cwd: cwd, config: config, attachOnly: attachOnly, onStatus: onStatus)
    }

    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        // Leave the PTY running server-side; only drop this renderer's socket.
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let terminalKey: String
        private let cwd: String
        private let config: CodevisorServerConfig
        private let attachOnly: Bool
        private let onStatus: (String?) -> Void
        private var transport: TerminalTransport?
        private weak var terminalView: SwiftTerm.TerminalView?
        private var opened = false

        init(
            terminalKey: String, cwd: String, config: CodevisorServerConfig, attachOnly: Bool,
            onStatus: @escaping (String?) -> Void
        ) {
            self.terminalKey = terminalKey
            self.cwd = cwd
            self.config = config
            self.attachOnly = attachOnly
            self.onStatus = onStatus
        }

        func attach(view: SwiftTerm.TerminalView) {
            terminalView = view
            guard !opened else { return }
            opened = true
            let transport = TerminalTransport(config: config) { [weak self] event in
                self?.handle(event)
            }
            self.transport = transport
            let terminal = view.getTerminal()
            let cols = max(2, terminal.cols)
            let rows = max(2, terminal.rows)
            Task {
                do {
                    try await transport.open(
                        sessionId: terminalKey, cwd: cwd, cols: cols, rows: rows, attachOnly: attachOnly)
                    self.onStatus(nil)
                } catch {
                    self.onStatus("Couldn't open \(config.baseURL.absoluteString): \(error.localizedDescription)")
                }
            }
        }

        func detach() {
            transport?.detach()
            transport = nil
        }

        private func handle(_ event: TerminalEvent) {
            switch event {
            case let .output(data):
                terminalView?.feed(text: data)
            case let .exit(code):
                onStatus("Shell exited\(code.map { " (\($0))" } ?? "")")
            case let .error(message):
                onStatus(message)
            }
        }

        // MARK: - TerminalViewDelegate

        nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self.transport?.sendInput(text)
            }
        }

        nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                self.transport?.sendResize(cols: newCols, rows: newRows)
            }
        }

        nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            Task { @MainActor in
                if let url = URL(string: link) {
                    UIApplication.shared.open(url)
                }
            }
        }
        nonisolated func bell(source: SwiftTerm.TerminalView) {}
        nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            Task { @MainActor in
                if let text = String(data: content, encoding: .utf8) {
                    UIPasteboard.general.string = text
                }
            }
        }
        nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
