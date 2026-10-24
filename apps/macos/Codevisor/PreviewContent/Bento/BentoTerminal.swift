#if DEBUG
  import AppKit
  import Darwin
  import GhosttyKit
  import SwiftUI

  struct BentoTerminal: NSViewRepresentable {
    let command: String

    static var home: String? { ProcessInfo.processInfo.environment["CODEVISOR_BENTO_TERMINAL_HOME"] }
    static var path: String { ProcessInfo.processInfo.environment["CODEVISOR_BENTO_TERMINAL_PATH"] ?? "/usr/bin:/bin" }

    private static let project = "emojis"
    private static let typingDelay: TimeInterval = 0.6

    final class Coordinator {
      var io: BentoTerminalIO?
      var renderer: GhosttySurfaceRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
      BentoLocalShell.closeAll()
      CodevisorGhosttyApp.applySystemAppearance(
        isDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
      let io = BentoTerminalIO.make()
      var config = Ghostty.SurfaceConfiguration()
      config.hostIO = io.surfaceIO
      config.waitAfterCommand = true
      let view = Ghostty.SurfaceView(CodevisorGhosttyApp.shared.app, baseConfig: config)
      CodevisorGhosttyApp.shared.register(view)
      let renderer = GhosttySurfaceRenderer(surface: view.surface, view: view)
      let command = command
      io.start = { [weak renderer] cols, rows in
        guard let home = Self.home else { return nil }
        let shell = BentoLocalShell(
          home: home, directory: "\(home)/\(Self.project)", path: Self.path, cols: cols, rows: rows)
        shell?.onOutput = { renderer?.writeLive($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingDelay) { shell?.type("\(command)\r") }
        return shell
      }
      context.coordinator.io = io
      context.coordinator.renderer = renderer
      return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
      coordinator.io?.shell?.close()
      if let view = nsView as? Ghostty.SurfaceView { CodevisorGhosttyApp.shared.unregister(view) }
    }
  }

  @MainActor
  final class BentoTerminalIO {
    var start: ((Int, Int) -> BentoLocalShell?)?
    private(set) var shell: BentoLocalShell?

    static func make() -> BentoTerminalIO {
      let io = BentoTerminalIO()
      _ = Unmanaged.passRetained(io)
      return io
    }

    private init() {}

    var surfaceIO: Ghostty.SurfaceConfiguration.HostIO {
      .init(
        userdata: Unmanaged.passUnretained(self).toOpaque(),
        receiveBuffer: Self.receiveBuffer,
        receiveResize: Self.receiveResize)
    }

    private static let receiveBuffer: ghostty_surface_receive_buffer_cb = { userdata, pointer, count in
      guard let userdata, let pointer, count > 0 else { return }
      let io = Unmanaged<BentoTerminalIO>.fromOpaque(userdata).takeUnretainedValue()
      let bytes = Array(UnsafeBufferPointer(start: pointer, count: count))
      DispatchQueue.main.async { MainActor.assumeIsolated { io.shell?.write(bytes) } }
    }

    private static let receiveResize: ghostty_surface_receive_resize_cb = { userdata, cols, rows, _, _ in
      guard let userdata else { return }
      let io = Unmanaged<BentoTerminalIO>.fromOpaque(userdata).takeUnretainedValue()
      DispatchQueue.main.async { MainActor.assumeIsolated { io.resize(cols: Int(cols), rows: Int(rows)) } }
    }

    private func resize(cols: Int, rows: Int) {
      if let shell {
        shell.resize(cols: cols, rows: rows)
      } else {
        shell = start?(cols, rows)
      }
    }
  }

  @MainActor
  final class BentoLocalShell {
    var onOutput: (([UInt8]) -> Void)?

    private static var running: [BentoLocalShell] = []
    private var isClosed = false
    private let pid: pid_t
    private let master: Int32
    private let reader: DispatchSourceRead
    private static let interrupt = "\u{3}"
    private static let readSize = 4096
    private static let exitPolls = 50
    private static let exitPollInterval: useconds_t = 20_000

    init?(home: String, directory: String, path: String, cols: Int, rows: Int) {
      let environment = [
        "HOME=\(home)", "PATH=\(path)", "TERM=xterm-256color", "LANG=en_US.UTF-8", "PS1=%~ ❯ ",
      ]
      let shell = ["/bin/zsh", "-f", "+m", "-i"]
      let arguments: [UnsafeMutablePointer<CChar>?] = shell.map { strdup($0) } + [nil]
      let variables: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
      let workingDirectory = strdup(directory)
      defer { (arguments + variables + [workingDirectory]).forEach { free($0) } }
      var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
      var master: Int32 = -1
      let pid = forkpty(&master, nil, nil, &size)
      if pid == 0 {
        chdir(workingDirectory)
        execve(arguments[0], arguments, variables)
        _exit(127)
      }
      guard pid > 0 else { return nil }
      self.pid = pid
      self.master = master
      reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
      reader.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.drain() }
      }
      reader.resume()
      Self.running.append(self)
    }

    static func closeAll() {
      running.forEach { $0.close() }
      running = []
    }

    func type(_ text: String) {
      write(Array(text.utf8))
    }

    func write(_ bytes: [UInt8]) {
      bytes.withUnsafeBufferPointer { _ = Darwin.write(master, $0.baseAddress, $0.count) }
    }

    func resize(cols: Int, rows: Int) {
      var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
      _ = ioctl(master, TIOCSWINSZ, &size)
    }

    func close() {
      guard !isClosed else { return }
      isClosed = true
      onOutput = nil
      reader.cancel()
      type(Self.interrupt)
      kill(-pid, SIGHUP)
      var status: Int32 = 0
      for _ in 0..<Self.exitPolls where waitpid(pid, &status, WNOHANG) == 0 {
        usleep(Self.exitPollInterval)
      }
      kill(-pid, SIGKILL)
      Darwin.close(master)
    }

    private func drain() {
      var buffer = [UInt8](repeating: 0, count: Self.readSize)
      let count = read(master, &buffer, Self.readSize)
      guard count > 0 else {
        reader.cancel()
        return
      }
      onOutput?(Array(buffer[0..<count]))
    }
  }
#endif
