#if os(macOS)
  import ScreenSharing
  import Foundation

  /// The host's side of Codevisor's control and clipboard protocols, played
  /// locally for a VNC server that has neither: every control request is
  /// granted at once (VNC has no consent step), input under the lease becomes
  /// RFB messages, and clipboard transfers bridge to ServerCutText and
  /// ClientCutText — as UTF-8 through the Extended Clipboard handshake when the
  /// server offers it (851-2316), Latin-1 otherwise. The viewer's lease
  /// reducer, input forwarder and clipboard transfer run unchanged against the
  /// near ends of two local channel pairs.
  @MainActor
  final class VNCHostEmulator {
    let controlChannel: ScreenSharingLocalChannel<ScreenSharingControlMessage>
    let clipboardChannel: ScreenSharingLocalChannel<ScreenSharingClipboardMessage>
    private let controlHost: ScreenSharingLocalChannel<ScreenSharingControlMessage>
    private let clipboardHost: ScreenSharingLocalChannel<ScreenSharingClipboardMessage>
    private let translator: VNCInputTranslator
    private let outbox: (RFBClientMessage) -> Void
    private var lease: UUID?
    private var serverText: String?
    private var transfer: ScreenSharingClipboardTransfer!
    /// The server sent Extended Clipboard caps that include text.
    private var extended = false
    /// Text announced to the server (notify), provided when it asks.
    private var announcedText: String?

    /// With a channel, control is codevisor-server's to give (851-2338): a request goes to the
    /// server, which grants it and may later revoke it for another viewer (last one wins).
    /// Without one, a VNC server has no notion of control and a request is granted at once.
    private let leaseChannel: (any RFBControlChannel)?
    private let viewerName: String
    private var pendingRequest: UUID?

    init(
      translator: VNCInputTranslator, leaseChannel: (any RFBControlChannel)? = nil,
      viewerName: String = Host.current().localizedName ?? "Another Mac",
      outbox: @escaping (RFBClientMessage) -> Void
    ) {
      self.translator = translator
      self.outbox = outbox
      self.leaseChannel = leaseChannel
      self.viewerName = viewerName
      (controlChannel, controlHost) = ScreenSharingLocalChannel.pair()
      (clipboardChannel, clipboardHost) = ScreenSharingLocalChannel.pair()
      transfer = ScreenSharingClipboardTransfer(
        send: { [weak clipboardHost] in clipboardHost?.send($0) ?? false },
        canReceiveUnsolicited: { true },
        read: { [weak self] in
          guard let text = self?.serverText else { throw NoServerText() }
          return text
        },
        write: { [weak self] text in self?.sendText(text) })
      controlHost.onMessage = { [weak self] in self?.handle($0) }
      clipboardHost.onMessage = { [weak self] in self?.transfer.receive($0) }
      leaseChannel?.onControlText = { [weak self] text in
        guard let message = RFBControlLeaseMessage.decode(text) else { return }
        Task { @MainActor in self?.serverLease(message) }
      }
    }

    /// The server's answer to a request, or another viewer taking control.
    func serverLease(_ message: RFBControlLeaseMessage) {
      switch message {
      case .granted:
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        let lease = UUID()
        self.lease = lease
        controlHost.send(.grant(request: request, lease: lease))
      case .revoked(let by):
        guard let lease else { return }
        self.lease = nil
        translator.release().forEach(outbox)
        controlHost.send(.revoked(lease: lease, reason: "\(by) took control."))
      }
    }

    var hasLease: Bool { lease != nil }

    func serverCutText(_ text: String) { serverText = text }

    /// The Extended Clipboard handshake, text only.
    func extendedClipboard(_ message: RFBExtendedClipboard.Message) {
      let text = RFBExtendedClipboard.text
      switch message {
      case .caps(let formats, _, _):
        guard formats & text != 0 else { return }
        extended = true
        outbox(
          .extendedClipboard(
            .caps(
              formats: text,
              actions: RFBExtendedClipboard.request | RFBExtendedClipboard.peek | RFBExtendedClipboard.notify
                | RFBExtendedClipboard.provide,
              maximumSizes: [UInt32(RFBExtendedClipboard.maximumBytes)])))
      case .notify(let formats):
        // The server's clipboard changed: fetch it now, so "Get Clipboard" has it.
        if formats & text != 0 { outbox(.extendedClipboard(.request(formats: text))) }
      case .request(let formats):
        if formats & text != 0 { outbox(.extendedClipboard(.provide(text: announcedText))) }
      case .peek:
        outbox(.extendedClipboard(.notify(formats: announcedText == nil ? 0 : text)))
      case .provide(let provided):
        if let provided { serverText = provided }
      }
    }

    private func sendText(_ text: String) {
      guard extended else {
        outbox(.clientCutText(text))  // Latin-1: a server without the extension
        return
      }
      announcedText = text
      outbox(.extendedClipboard(.notify(formats: RFBExtendedClipboard.text)))
    }

    func close() {
      lease = nil
      transfer.cancel()
      controlHost.close()
      clipboardHost.close()
    }

    private func handle(_ message: ScreenSharingControlMessage) {
      switch message {
      case .request(let id):
        if let leaseChannel {
          pendingRequest = id
          let text = RFBControlLeaseMessage.request(name: viewerName)
          Task { try? await leaseChannel.sendControlText(text) }
          return
        }
        let lease = UUID()
        self.lease = lease
        controlHost.send(.grant(request: id, lease: lease))
      case .release(let lease):
        guard self.lease == lease else { return }
        self.lease = nil
        translator.release().forEach(outbox)
        if let leaseChannel { Task { try? await leaseChannel.sendControlText(RFBControlLeaseMessage.release) } }
      case .input(let lease, _, let event):
        guard self.lease == lease else { return }
        translator.translate(event).forEach(outbox)
      case .heartbeat, .grant, .denied, .revoked:
        break
      }
    }

    private struct NoServerText: LocalizedError {
      var errorDescription: String? { "The VNC server has not shared any clipboard text yet." }
    }
  }
#endif
