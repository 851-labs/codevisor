#if os(macOS)
  import Foundation
  import ScreenSharing
  import ScreenSharingTesting
  import SwiftUI

  /// The in-process reference VNC server from the tests, started and stopped
  /// from the window: the animated desktop the `vnc-server` subcommand paints,
  /// or one of the deterministic scenes the tests and `vnc-bench` play.
  @MainActor
  @Observable
  final class RigLoopbackServerModel {
    var password = "secret"
    var width = 1280
    var height = 800
    var framesPerSecond = 10
    var encoding: RFBEncoding = .zrle
    var animated = true
    /// nil: the animated desktop; otherwise a reference scene (seed 1).
    var scene: RFBLoopbackScene.Kind?
    /// Answer pointer events with the reference server's echo marker.
    var echoPointer = false
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
      configuration.echoPointer = echoPointer
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
          if let scene = self.scene {
            self.play(server: server, scene: scene, fps: framesPerSecond)
          } else {
            self.paint(server: server, width: width, height: height, fps: framesPerSecond, encoding: encoding)
          }
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

    /// One scene frame per tick; a frame the client hasn't taken yet holds the scene back.
    private func play(server: RFBLoopbackServer, scene kind: RFBLoopbackScene.Kind, fps: Int) {
      painting = Task { [weak self] in
        var scene = RFBLoopbackScene(kind: kind, seed: 1)
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(1000 / max(1, fps)))
          guard let self else { return }
          guard self.animated || scene.frame == 0 else { continue }
          _ = try? server.play(&scene)
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
          TextField("Width", value: Bindable(model).width, format: .number)
          TextField("Height", value: Bindable(model).height, format: .number)
          TextField("FPS", value: Bindable(model).framesPerSecond, format: .number)
          Picker("Encoding", selection: Bindable(model).encoding) {
            Text("ZRLE").tag(RFBEncoding.zrle)
            Text("Raw").tag(RFBEncoding.raw)
          }
          Picker("Content", selection: Bindable(model).scene) {
            Text("Animated desktop").tag(RFBLoopbackScene.Kind?.none)
            ForEach(RFBLoopbackScene.Kind.allCases, id: \.self) { kind in
              Text("Scene: \(kind.rawValue)").tag(Optional(kind))
            }
          }
          Toggle("Animate (off: one frame, like a static desktop)", isOn: Bindable(model).animated)
          Toggle("Echo pointer input as a marker", isOn: Bindable(model).echoPointer)
        }
        .formStyle(.grouped)
        .frame(maxHeight: 360)
        Text(model.status).foregroundStyle(.secondary).padding(.horizontal, 20)
        Text("Input received").font(.headline).padding(.horizontal, 20)
        ScrollView {
          Text(model.log.suffix(60).joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
        }
      }
      .padding(.vertical, 12)
      .navigationTitle("Loopback VNC server")
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          if model.port == nil {
            Button {
              model.start()
            } label: {
              Label("Start", systemImage: "play.fill")
            }
            .keyboardShortcut(.defaultAction)
            .help("Start the loopback VNC server")
          } else {
            Button {
              view()
            } label: {
              Label("View", systemImage: "display")
            }
            .keyboardShortcut(.defaultAction)
            .help("View it under Machines")
            Button {
              model.stop()
            } label: {
              Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop the loopback VNC server")
          }
        }
      }
    }
  }
#endif
