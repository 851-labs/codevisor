#if os(macOS)
  import AppKit
  import SwiftUI

  /// The rig's window: a sidebar of scenarios, each a way to exercise the
  /// screen-sharing stack outside the product. Launched without arguments it
  /// opens on Raw VNC; the resident viewer (`--config`) opens the same window
  /// on Native session with its video inside. `probe`, `vnc-server` and the
  /// `--config` host remain headless entry points the scripts drive.
  enum RigScenario: String, CaseIterable, Identifiable {
    case rawVNC, loopbackServer, nativeSession, probe
    var id: String { rawValue }

    var title: String {
      switch self {
      case .rawVNC: "Raw VNC"
      case .loopbackServer: "Loopback VNC server"
      case .nativeSession: "Native session"
      case .probe: "Probe"
      }
    }

    var systemImage: String {
      switch self {
      case .rawVNC: "network"
      case .loopbackServer: "server.rack"
      case .nativeSession: "display.2"
      case .probe: "waveform.path.ecg"
      }
    }
  }

  @MainActor
  enum RigShell {
    /// Opens the shell window and runs the application until it closes. With
    /// the resident viewer's `runner`, Native session hosts its video and the
    /// runner is the window's delegate: closing it stops the session and exits
    /// cleanly, which the launch agent does not restart.
    static func run(runner: RigRunner? = nil) -> Never {
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)
      let controller = NSHostingController(rootView: RigShellView(runner: runner))
      let window = NSWindow(contentViewController: controller)
      window.title = runner == nil ? "Codevisor Screen Sharing Rig" : "Codevisor Screen Sharing Rig · viewer"
      window.setContentSize(NSSize(width: 1180, height: 760))
      window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
      window.titlebarAppearsTransparent = true
      window.isReleasedWhenClosed = false
      window.center()
      if let runner {
        window.delegate = runner
        runner.window = window
      }
      window.makeKeyAndOrderFront(nil)
      app.activate(ignoringOtherApps: true)
      let delegate = RigShellDelegate()
      app.delegate = delegate
      withExtendedLifetime((window, delegate)) { app.run() }
      exit(EXIT_SUCCESS)
    }
  }

  private final class RigShellDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  }

  struct RigShellView: View {
    let runner: RigRunner?
    @State private var scenario: RigScenario?
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var vnc = RigVNCScenarioModel()
    @State private var loopback = RigLoopbackServerModel()

    init(runner: RigRunner?) {
      self.runner = runner
      _scenario = State(initialValue: runner == nil ? .rawVNC : .nativeSession)
    }

    var body: some View {
      NavigationSplitView(columnVisibility: $columns) {
        List(RigScenario.allCases, selection: $scenario) { scenario in
          Label(scenario.title, systemImage: scenario.systemImage).tag(scenario)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
      } detail: {
        switch scenario ?? .rawVNC {
        case .rawVNC: RigVNCScenarioView(model: vnc, loopback: loopback)
        case .loopbackServer: RigLoopbackServerView(model: loopback)
        case .nativeSession:
          if let runner { RigNativeSessionView(runner: runner) } else { RigInstructionsView.nativeSession }
        case .probe: RigInstructionsView.probe
        }
      }
      // A sample measures presented frames with nothing else on screen: only the video, no sidebar.
      .onChange(of: runner?.nativeSession.sampling ?? false) { _, sampling in
        if sampling { scenario = .nativeSession }
        columns = sampling ? .detailOnly : .all
      }
    }
  }

  /// Scenarios that stay command-driven: what to run and where their documentation is.
  struct RigInstructionsView: View {
    let title: String
    let lines: [String]

    static let nativeSession = RigInstructionsView(
      title: "Native session",
      lines: [
        "The two-Mac WebRTC rig runs as LaunchAgents driven by rig.json; the viewer opens this window with its video here.",
        "bun run screen-sharing:rig install --host user@mac --host-address 192.168.x.y --capture workload:1920x1080@60",
        "bun run screen-sharing:rig status · sample --seconds 30 · tune paced15-worker · logs · stop --all",
        "See docs/plans/screen-sharing-rig.md and apps/screen-sharing-rig/README.md.",
      ])

    static let probe = RigInstructionsView(
      title: "Probe",
      lines: [
        "The single-process capture → encode → decode → render diagnostic.",
        "bun scripts/screen-sharing-probe.mjs --help",
        "swift run --package-path apps/screen-sharing-rig screen-sharing-rig probe --mode loopback --duration 10",
      ])

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.title2.bold())
        ForEach(lines, id: \.self) { line in
          Text(line).font(
            line.contains(" ") && !line.hasPrefix("bun") && !line.hasPrefix("swift")
              ? .body : .system(.body, design: .monospaced)
          )
          .textSelection(.enabled)
        }
        Spacer()
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
#endif
