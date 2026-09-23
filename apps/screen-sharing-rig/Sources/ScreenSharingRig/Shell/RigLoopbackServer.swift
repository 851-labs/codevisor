#if os(macOS)
  import Foundation
  import ScreenSharing
  import ScreenSharingTesting
  import SwiftUI

  /// The in-process VNC server from the tests, with the animated desktop the
  /// `vnc-server` subcommand paints, started and stopped from the window.
  @MainActor
  @Observable
  final class RigLoopbackServerModel {
    var password = "secret"
    var width = 1280
    var height = 800
    var framesPerSecond = 10
    var encoding: RFBEncoding = .zrle
    var animated = true
    private(set) var port: UInt16?
    private(set) var status = "Stopped"
    private(set) var log: [String] = []
    @ObservationIgnored private var server: RFBLoopbackServer?
    @ObservationIgnored private var painting: Task<Void, Never>?

    func start() {
      stop()
      var configuration = RFBLoopbackServer.Configuration()
      configuration.password = password.isEmpty ? nil : password
      configuration.securityTypes = [
        password.isEmpty ? RFBSecurityType.none.rawValue : RFBSecurityType.vncAuthentication.rawValue
      ]
      configuration.width = width
      configuration.height = height
      configuration.name = "Codevisor rig \(width)×\(height)"
      configuration.encoding = encoding
      status = "Starting…"
      Task { [weak self] in
        do {
          let server = try await RFBLoopbackServer(configuration: configuration)
          guard let self else { return }
          server.onClientMessage = { [weak self] message in
            Task { @MainActor in self?.record(message) }
          }
          self.server = server
          self.port = server.port
          self.status = "Serving on 127.0.0.1:\(server.port)"
          self.paint(server: server, width: width, height: height, fps: framesPerSecond, encoding: encoding)
        } catch {
          self?.status = error.localizedDescription
        }
      }
    }

    private func paint(server: RFBLoopbackServer, width: Int, height: Int, fps: Int, encoding: RFBEncoding) {
      let full = RFBRectangle(x: 0, y: 0, width: width, height: height)
      painting = Task { [weak self] in
        var painter = VNCServerCommand.Painter(width: width, height: height)
        var first = true
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(1000 / max(1, fps)))
          guard let self else { return }
          if first || self.animated {
            try? server.paint(full, pixels: painter.nextFrame())
            first = false
            if server.isRequestPending { server.enqueue([encoding == .zrle ? .zrle(full) : .raw(full)]) }
          }
        }
      }
    }

    private func record(_ message: RFBClientMessage) {
      let line: String? =
        switch message {
        case .keyEvent(let keysym, let down): "key \(String(keysym, radix: 16)) \(down ? "down" : "up")"
        case .pointerEvent(let buttons, let x, let y) where buttons != 0:
          "buttons \(String(buttons, radix: 2)) at \(x),\(y)"
        case .clientCutText(let text): "clipboard: \(text)"
        default: nil
        }
      guard let line else { return }
      log.append(line)
      if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func stop() {
      painting?.cancel()
      painting = nil
      server?.stop()
      server = nil
      port = nil
      status = "Stopped"
    }
  }

  struct RigLoopbackServerView: View {
    let model: RigLoopbackServerModel
    /// Selects the "Loopback server" machine the sidebar lists while it serves.
    let view: () -> Void

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Form {
          TextField("Password (empty for none)", text: Bindable(model).password)
          HStack {
            TextField("Width", value: Bindable(model).width, format: .number)
            TextField("Height", value: Bindable(model).height, format: .number)
            TextField("FPS", value: Bindable(model).framesPerSecond, format: .number)
          }
          Picker("Encoding", selection: Bindable(model).encoding) {
            Text("ZRLE").tag(RFBEncoding.zrle)
            Text("Raw").tag(RFBEncoding.raw)
          }
          Toggle("Animate (off: one frame, like a static desktop)", isOn: Bindable(model).animated)
        }
        .formStyle(.grouped)
        .frame(maxHeight: 260)
        HStack {
          if model.port == nil {
            Button("Start") { model.start() }.keyboardShortcut(.defaultAction)
          } else {
            Button("View") { view() }.keyboardShortcut(.defaultAction)
            Button("Stop") { model.stop() }
          }
          Text(model.status).foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.horizontal, 20)
        Text("Input received").font(.headline).padding(.horizontal, 20)
        ScrollView {
          Text(model.log.suffix(60).joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
        }
      }
      .padding(.vertical, 12)
      .navigationTitle("Loopback VNC server")
    }
  }
#endif
