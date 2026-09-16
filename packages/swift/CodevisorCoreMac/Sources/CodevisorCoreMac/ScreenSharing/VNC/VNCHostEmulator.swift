import CodevisorScreenSharing
import Foundation
import ScreenSharingRFB

/// The host's side of Codevisor's control and clipboard protocols, played
/// locally for a VNC server that has neither: every control request is
/// granted at once (VNC has no consent step), input under the lease becomes
/// RFB messages, and clipboard transfers bridge to ServerCutText and
/// ClientCutText. The viewer's lease reducer, input forwarder and clipboard
/// transfer run unchanged against the near ends of two local channel pairs.
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

  init(translator: VNCInputTranslator, outbox: @escaping (RFBClientMessage) -> Void) {
    self.translator = translator
    self.outbox = outbox
    (controlChannel, controlHost) = ScreenSharingLocalChannel.pair()
    (clipboardChannel, clipboardHost) = ScreenSharingLocalChannel.pair()
    transfer = ScreenSharingClipboardTransfer(
      send: { [weak clipboardHost] in clipboardHost?.send($0) ?? false },
      canReceiveUnsolicited: { true },
      read: { [weak self] in
        guard let text = self?.serverText else { throw NoServerText() }
        return text
      },
      write: { [weak self] text in self?.outbox(.clientCutText(text)) })
    controlHost.onMessage = { [weak self] in self?.handle($0) }
    clipboardHost.onMessage = { [weak self] in self?.transfer.receive($0) }
  }

  var hasLease: Bool { lease != nil }

  func serverCutText(_ text: String) { serverText = text }

  func close() {
    lease = nil
    transfer.cancel()
    controlHost.close()
    clipboardHost.close()
  }

  private func handle(_ message: ScreenSharingControlMessage) {
    switch message {
    case .request(let id):
      let lease = UUID()
      self.lease = lease
      controlHost.send(.grant(request: id, lease: lease))
    case .release(let lease):
      guard self.lease == lease else { return }
      self.lease = nil
      translator.release().forEach(outbox)
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
