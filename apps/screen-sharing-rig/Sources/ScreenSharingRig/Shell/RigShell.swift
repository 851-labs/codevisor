#if os(macOS)
  import AppKit
  import SwiftUI

  /// The rig's window when launched without arguments: a sidebar of scenarios,
  /// each a way to exercise the screen-sharing stack outside the product.
  /// `--config` (the resident two-Mac rig), `probe` and `vnc-server` remain the
  /// headless entry points the scripts drive.
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
    /// Opens the shell window and runs the application until it closes.
    static func run() -> Never {
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)
      let controller = NSHostingController(rootView: RigShellView())
      let window = NSWindow(contentViewController: controller)
      window.title = "Codevisor Screen Sharing Rig"
      window.setContentSize(NSSize(width: 1180, height: 760))
      window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
      window.titlebarAppearsTransparent = true
      window.center()
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
    @State private var scenario: RigScenario? = .rawVNC
    @State private var vnc = RigVNCScenarioModel()
    @State private var loopback = RigLoopbackServerModel()

    var body: some View {
      NavigationSplitView {
        List(RigScenario.allCases, selection: $scenario) { scenario in
          Label(scenario.title, systemImage: scenario.systemImage).tag(scenario)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
      } detail: {
        switch scenario ?? .rawVNC {
        case .rawVNC: RigVNCScenarioView(model: vnc, loopback: loopback)
        case .loopbackServer: RigLoopbackServerView(model: loopback)
        case .nativeSession: RigInstructionsView.nativeSession
        case .probe: RigInstructionsView.probe
        }
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
        "The two-Mac WebRTC rig runs as LaunchAgents driven by rig.json, not from this window.",
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
