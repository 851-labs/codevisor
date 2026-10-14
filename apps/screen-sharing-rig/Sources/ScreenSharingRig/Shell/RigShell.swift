#if os(macOS)
  import AppKit
  import ScreenSharingRigKit
  import SwiftUI

  enum RigScenario: String, CaseIterable, Identifiable {
    case loopbackServer, nativeSession
    var id: String { rawValue }

    var title: String {
      switch self {
      case .loopbackServer: "Loopback VNC server"
      case .nativeSession: "Native session"
      }
    }

    var systemImage: String {
      switch self {
      case .loopbackServer: "server.rack"
      case .nativeSession: "display.2"
      }
    }
  }

  @MainActor
  enum RigShell {
    static func run(runner: RigRunner? = nil) -> Never {
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)
      RigMainMenu.install()
      let controller = NSHostingController(rootView: RigShellView(runner: runner))
      controller.sceneBridgingOptions = [.toolbars, .title]
      let window = NSWindow(contentViewController: controller)
      window.title = runner == nil ? "Codevisor Screen Sharing Rig" : "Codevisor Screen Sharing Rig · viewer"
      window.setContentSize(NSSize(width: 1180, height: 760))
      window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
      window.toolbarStyle = .unified
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

  enum RigSidebarItem: Hashable {
    case machine(String)
    case scenario(RigScenario)
  }

  struct RigShellView: View {
    let runner: RigRunner?
    @State private var selection: RigSidebarItem?
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var loopback = RigLoopbackServerModel()
    @State private var catalog: [RigMachineModel]
    @State private var loopbackMachine: RigMachineModel?

    init(runner: RigRunner?) {
      self.runner = runner
      _catalog = State(initialValue: RigMachine.catalog.map { RigMachineModel(machine: $0) })
      let first: RigSidebarItem = RigMachine.catalog.first.map { .machine($0.id) } ?? .scenario(.loopbackServer)
      _selection = State(initialValue: runner == nil ? first : .scenario(.nativeSession))
    }

    private var machines: [RigMachineModel] { catalog + (loopbackMachine.map { [$0] } ?? []) }

    var body: some View {
      NavigationSplitView(columnVisibility: $columns) {
        List(selection: $selection) {
          Section("Machines") {
            ForEach(machines, id: \.machine.id) { model in
              Label(model.machine.name, systemImage: model.machine.systemImage)
                .tag(RigSidebarItem.machine(model.machine.id))
            }
          }
          Section("Debug") {
            ForEach(RigScenario.allCases) { scenario in
              Label(scenario.title, systemImage: scenario.systemImage).tag(RigSidebarItem.scenario(scenario))
            }
          }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
      } detail: {
        switch selection {
        case .machine(let id):
          if let model = machines.first(where: { $0.machine.id == id }) {
            RigMachineView(model: model).id(id)
          }
        case nil: ContentUnavailableView("Select a machine", systemImage: "display")
        case .scenario(.loopbackServer):
          RigLoopbackServerView(model: loopback) {
            if let id = loopbackMachine?.machine.id { selection = .machine(id) }
          }
        case .scenario(.nativeSession):
          if let runner { RigNativeSessionView(runner: runner) } else { RigInstructionsView.nativeSession }
        }
      }
      .toolbar {
        ToolbarItem(id: "rig.sidebar", placement: .navigation) {
          Button {
            withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
          } label: {
            Label("Toggle Sidebar", systemImage: "sidebar.left")
          }
          .help("Show or hide the sidebar")
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: RigMainMenu.toggleSidebar)) { _ in
        withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
      }
      .onChange(of: loopback.port) { _, port in
        loopbackMachine = port.map {
          RigMachineModel(machine: .loopback(port: $0, password: loopback.password.isEmpty ? nil : loopback.password))
        }
        let loopbackId = RigMachine.loopback(port: 0, password: nil).id
        if loopbackMachine == nil, case .machine(loopbackId) = selection { selection = .scenario(.loopbackServer) }
      }
      .onChange(of: runner?.nativeSession.sampling ?? false) { _, sampling in
        if sampling { selection = .scenario(.nativeSession) }
        columns = sampling ? .detailOnly : .all
      }
    }
  }

  struct RigInstructionsView: View {
    let title: String
    let lines: [String]

    static let nativeSession = RigInstructionsView(
      title: "Native session",
      lines: [
        "The two-Mac WebRTC rig runs as LaunchAgents driven by rig.json; the viewer opens this window with its video here.",
        "bun run screen-sharing:rig install --host user@mac --host-address 192.168.x.y --capture workload:1920x1080@60",
        "bun run screen-sharing:rig status · sample --seconds 30 · tune paced15-worker · logs · stop --all",
        "See apps/screen-sharing-rig/README.md.",
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
      .navigationTitle(title)
    }
  }
#endif
