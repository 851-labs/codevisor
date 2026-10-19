#if os(macOS)
  import Foundation

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
    private var extended = false
    private var announcedText: String?
    var sharing = false {
      didSet {
        if !sharing { waiting = nil }
        if relaying, sharing != oldValue { sendControlText(VNCClipboardRelayMessage.viewer(sharing: sharing)) }
      }
    }
    var onRichClipboardSupported: (() -> Void)?
    private var waiting: String?
    private var echo: String?
    private var relaying = false
    private var controlOutbox: AsyncStream<String>.Continuation?
    private var controlTasks: [Task<Void, Never>] = []

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
        read: { [weak self] _ in
          guard let text = self?.serverText else { throw NoServerText() }
          return .init(text: text)
        },
        write: { [weak self] content in
          guard let text = content.text else { throw NoText() }
          self?.sendText(text)
        })
      transfer.onFinished = { [weak self] _ in
        guard let self, let text = self.waiting else { return }
        self.waiting = nil
        self.share(text)
      }
      controlHost.onMessage = { [weak self] in self?.handle($0) }
      clipboardHost.onMessage = { [weak self] message in
        guard let self else { return }
        guard self.relaying else {
          self.transfer.receive(message)
          return
        }
        if let text = VNCClipboardRelayMessage.encode(message) { self.sendControlText(text) }
      }
      if let leaseChannel {
        let (outgoing, outbox) = AsyncStream<String>.makeStream()
        let (incoming, inbox) = AsyncStream<String>.makeStream()
        controlOutbox = outbox
        leaseChannel.onControlText = { inbox.yield($0) }
        controlTasks = [
          Task { for await text in outgoing { try? await leaseChannel.sendControlText(text) } },
          Task { @MainActor [weak self] in
            for await text in incoming { self?.receiveControlText(text) }
          },
        ]
      }
    }

    private func receiveControlText(_ text: String) {
      if let message = RFBControlLeaseMessage.decode(text) {
        serverLease(message)
        return
      }
      switch VNCClipboardRelayMessage.decode(text) {
      case .host(richContent: true):
        guard !relaying else { return }
        relaying = true
        waiting = nil
        transfer.cancel(reason: "The clipboard moved to the desktop's own channel.")
        sendControlText(VNCClipboardRelayMessage.viewer(sharing: sharing))
        onRichClipboardSupported?()
      case .transfer(let message):
        if relaying { clipboardHost.send(message) }
      case .host(richContent: false), nil:
        break
      }
    }

    private func sendControlText(_ text: String) { controlOutbox?.yield(text) }

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

    func serverCutText(_ text: String) {
      serverText = text
      share(text)
    }

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
        if formats & text != 0 { outbox(.extendedClipboard(.request(formats: text))) }
      case .request(let formats):
        if formats & text != 0 { outbox(.extendedClipboard(.provide(text: announcedText))) }
      case .peek:
        outbox(.extendedClipboard(.notify(formats: announcedText == nil ? 0 : text)))
      case .provide(let provided):
        if let provided {
          serverText = provided
          share(provided)
        }
      }
    }

    private func share(_ text: String) {
      guard sharing, !relaying else { return }
      guard text != echo else {
        echo = nil
        return
      }
      echo = nil
      guard !transfer.isBusy else {
        waiting = text
        return
      }
      transfer.sendContent(.init(text: text))
    }

    private func sendText(_ text: String) {
      echo = text
      guard extended else {
        outbox(.clientCutText(text))
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
      controlOutbox?.finish()
      controlTasks.forEach { $0.cancel() }
    }

    private func handle(_ message: ScreenSharingControlMessage) {
      switch message {
      case .request(let id):
        if leaseChannel != nil {
          pendingRequest = id
          sendControlText(RFBControlLeaseMessage.request(name: viewerName))
          return
        }
        let lease = UUID()
        self.lease = lease
        controlHost.send(.grant(request: id, lease: lease))
      case .release(let lease):
        guard self.lease == lease else { return }
        self.lease = nil
        translator.release().forEach(outbox)
        if leaseChannel != nil { sendControlText(RFBControlLeaseMessage.release) }
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

    private struct NoText: LocalizedError {
      var errorDescription: String? { "This VNC server accepts only plain text." }
    }
  }
#endif
