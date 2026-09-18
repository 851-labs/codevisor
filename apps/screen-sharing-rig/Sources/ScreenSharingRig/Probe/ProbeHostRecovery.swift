#if os(macOS)
  import AppKit
  import CodevisorClient
  import ScreenSharing
  import ScreenSharingWebRTC

  /// A focused integration check against the actual native host API. It uses a
  /// supplied test pane, never posts OS input and never accesses either clipboard.
  @MainActor
  final class ProbeHostRecovery {
    private let client: CodevisorServerClient
    private let workspace: UUID
    private let pane: UUID
    private let viewer = UUID()
    private let metrics = ScreenSharingMetrics()
    private var peer: ScreenSharingReceiver?
    private var view: ScreenSharingMetalView?
    private var window: NSWindow?
    private var display: String?
    private var lastOffer: String?

    init(url: URL, workspace: UUID, pane: UUID) {
      self.workspace = workspace; self.pane = pane
      client = CodevisorServerClient(
        config: .init(
          baseURL: url,
          bearerToken: ProcessInfo.processInfo.environment["CODEVISOR_SCREEN_SHARING_PROBE_TOKEN"]))
    }
    func run(report: URL?) async throws {
      do {
        try await connect(restarting: false)
        let wrongOwner = ServerScreenSharingRequest(
          operation: .restart, workspaceId: workspace,
          paneId: pane, viewerId: UUID(), displayId: display, offer: lastOffer)
        guard try await client.screenSharing(wrongOwner).status == "stopped" else {
          throw ScreenSharingError.invalid("Host accepted a replacement from the wrong viewer.")
        }
        try await waitForVideo()
        peer?.close(); peer = nil; view?.isPaused = true
        try await connect(restarting: true)
        _ = try await client.screenSharing(request(.stop))
        let denied = try await client.screenSharing(request(.restart, offer: lastOffer))
        guard denied.status == "stopped" else {
          throw ScreenSharingError.invalid("Host restarted a stopped lease.")
        }
        let value = Report(
          passed: true,
          checks: [
            "initial video", "wrong viewer rejected without stopping video",
            "fresh media peer on existing lease", "stopped lease cannot restart",
          ], receiver: metrics.snapshot())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if let report { try data.write(to: report, options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
        await stop()
      } catch { await stop(); throw error }
    }
    private func connect(restarting: Bool) async throws {
      let reply = try await client.screenSharing(request(.capabilities))
      guard ["available", "busy"].contains(reply.status), let selected = reply.displays.first else {
        throw ScreenSharingError.unavailable(reply.message ?? "No native host display is available.")
      }
      if display == nil { display = selected.id }
      let connectivity = try ScreenSharingICEConfiguration(
        servers: reply.connectivity?.servers.map {
          try ScreenSharingICEServer(urls: $0.urls, username: $0.username, credential: $0.credential)
        } ?? [], relayOnly: reply.connectivity?.relayOnly ?? false)
      let receiver = try ScreenSharingReceiver(configuration: .init(), metrics: metrics, connectivity: connectivity)
      peer = receiver
      let view = try ScreenSharingMetalView(mailbox: receiver.mailbox, metrics: metrics)
      self.view = view
      if window == nil {
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Codevisor · Host Recovery Check"; window.center(); self.window = window
      }
      window?.contentView = view; window?.makeKeyAndOrderFront(nil)
      let offer = try await receiver.makeDescription(offer: true)
      lastOffer = offer.sdp
      let answer = try await client.screenSharing(request(restarting ? .restart : .start, offer: offer.sdp))
      guard answer.status == "connecting", let sdp = answer.answer else {
        throw ScreenSharingError.unavailable(answer.message ?? "The native host rejected the connection.")
      }
      try await receiver.accept(.init(kind: "answer", sdp: sdp))
      try await waitForVideo()
    }
    private func waitForVideo() async throws {
      guard let view else { throw ScreenSharingError.invalid("No native viewer.") }
      let baseline = metrics.snapshot().counters["presentedFrames", default: 0]
      var completion: CheckedContinuation<Void, any Error>?
      let timeout = Task {
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        let pending = completion; completion = nil
        pending?.resume(throwing: ScreenSharingError.unavailable("No frames arrived during native host recovery."))
      }
      defer { timeout.cancel(); view.onPresented = nil }
      try await withCheckedThrowingContinuation { continuation in
        completion = continuation
        view.onPresented = { [weak self] _ in
          guard let self, self.metrics.snapshot().counters["presentedFrames", default: 0] >= baseline + 3 else {
            return
          }
          let pending = completion; completion = nil; pending?.resume()
        }
      }
    }
    private func stop() async {
      view?.isPaused = true; peer?.close(); peer = nil; window?.orderOut(nil)
      _ = try? await client.screenSharing(request(.stop))
    }
    private func request(
      _ operation: ServerScreenSharingRequest.Operation, offer: String? = nil
    ) -> ServerScreenSharingRequest {
      .init(
        operation: operation, workspaceId: workspace, paneId: pane, viewerId: viewer, displayId: display, offer: offer)
    }
    private struct Report: Encodable {
      let passed: Bool
      let checks: [String]
      let receiver: ScreenSharingMetrics.Snapshot
    }
  }
#endif
