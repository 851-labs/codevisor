#if os(macOS)
  import AppKit
  import ScreenSharing
  import SwiftUI

  /// A VNC server by host, port and password, rendered into the product's own
  /// surface with the product's own session: what the app does for a VPS
  /// workspace, minus the server that decides it. Control is granted at once
  /// (the emulated host lease) and input is forwarded under it.
  @MainActor
  @Observable
  final class RigVNCScenarioModel {
    var host = "127.0.0.1"
    var port = "5901"
    var password = ""
    private(set) var status = "Not connected"
    private(set) var surface: ScreenSharingVideoSurface?
    private(set) var metricsText = ""
    @ObservationIgnored private var session: VNCScreenSharingSession?
    @ObservationIgnored private var forwarder: ScreenSharingInputForwarder?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var sampler: Task<Void, Never>?

    var isConnected: Bool { session != nil }

    func connect() {
      disconnect()
      guard let port = UInt16(port.trimmingCharacters(in: .whitespaces)) else {
        status = "Invalid port"
        return
      }
      let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
      let password = password.isEmpty ? nil : password
      status = "Connecting to \(host):\(port)…"
      connectTask = Task { [weak self] in
        do {
          let (client, outcome) = try await VNCConnection.open(host: host, port: port, password: password)
          guard let self, !Task.isCancelled else {
            client.close()
            return
          }
          self.attach(client: client, outcome: outcome)
        } catch {
          self?.status = error.localizedDescription
        }
      }
    }

    private func attach(client: RFBClient, outcome: RFBHandshake.Outcome) {
      let session = VNCScreenSharingSession(client: client, parameters: outcome.parameters)
      do {
        let surface = try ScreenSharingVideoSurface(mailbox: session.frames, metrics: session.metrics)
        let forwarder = ScreenSharingInputForwarder(send: { [weak session] in session?.control?.send($0) ?? false })
        surface.onInput = { [weak forwarder] in forwarder?.forward($0) }
        surface.onPresented = { [weak self] in
          guard let self, !self.status.hasPrefix("Viewing") else { return }
          self.status =
            "Viewing \(outcome.parameters.name) · \(outcome.parameters.width) × \(outcome.parameters.height)"
        }
        session.control?.onMessage = { [weak self, weak surface, weak forwarder] message in
          guard case .grant(_, let lease) = message else { return }
          forwarder?.begin(lease: lease)
          if surface?.beginInput() != true { self?.status += " · input capture refused" }
        }
        session.control?.send(.request(id: UUID()))
        session.onConnectionChanged = { [weak self] transport in
          self?.status = "Connection \(transport)"
        }
        self.session = session
        self.forwarder = forwarder
        self.surface = surface
        status = "Connected · waiting for the first frame"
        sampler = Task { [weak self] in
          while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let self, let session = self.session else { return }
            let snapshot = session.metrics.snapshot()
            let keys = [
              "vncUpdatesPublished", "vncRectangles", "presentedFrames", "renderDrops", "unpresentedDrawables",
            ]
            self.metricsText = keys.compactMap { key in snapshot.counters[key].map { "\(key) \($0)" } }.joined(
              separator: "   ")
          }
        }
      } catch {
        session.close()
        status = error.localizedDescription
      }
    }

    func disconnect() {
      connectTask?.cancel()
      connectTask = nil
      sampler?.cancel()
      sampler = nil
      forwarder?.end()
      forwarder = nil
      surface?.stop()
      surface = nil
      session?.close()
      session = nil
      metricsText = ""
      status = "Not connected"
    }
  }

  struct RigVNCScenarioView: View {
    let model: RigVNCScenarioModel
    let loopback: RigLoopbackServerModel

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          TextField("Host", text: Bindable(model).host).frame(minWidth: 180)
          TextField("Port", text: Bindable(model).port).frame(width: 70)
          SecureField("Password", text: Bindable(model).password).frame(minWidth: 140)
          if model.isConnected {
            Button("Disconnect") { model.disconnect() }
          } else {
            Button("Connect") { model.connect() }.keyboardShortcut(.defaultAction)
          }
          if let port = loopback.port {
            Button("Use loopback server") {
              model.host = "127.0.0.1"
              model.port = String(port)
              model.password = loopback.password
            }
          }
          Spacer()
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        Divider()
        ZStack {
          Color.black
          if let surface = model.surface {
            RigSurfaceView(view: surface)
          } else {
            Text(model.status).foregroundStyle(.secondary)
          }
        }
        Divider()
        HStack {
          Text(model.status).font(.caption)
          Spacer()
          Text(model.metricsText).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
      }
      .navigationTitle("Raw VNC")
    }
  }

  struct RigSurfaceView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
  }
#endif
