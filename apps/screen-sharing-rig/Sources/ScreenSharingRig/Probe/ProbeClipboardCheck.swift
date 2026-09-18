import ScreenSharing
import ScreenSharingWebRTC
import Foundation

/// Exercises the real encrypted channel using in-memory clipboards. Never
/// reads or writes the diagnostic machine's general pasteboard.
@MainActor
final class ProbeClipboardCheck {
  private let hostChannel: ScreenSharingClipboardChannel
  private let viewerChannel: ScreenSharingClipboardChannel
  private let localText = String(repeating: "Codevisor café 👩🏽‍💻 日本語\n", count: 1000)
  private let remoteText = String(repeating: "Remote ✓ Ελληνικά 한국어\n", count: 1000)
  private var hostText = ""
  private var viewerText = ""
  private var stage = 0
  private var completion: CheckedContinuation<Void, any Error>?
  private var timeout: Task<Void, Never>?
  private lazy var host = ScreenSharingClipboardTransfer(
    send: { [weak self] in self?.hostChannel.send($0) ?? false },
    canReceiveUnsolicited: { true }, read: { [unowned self] in hostText },
    write: { [unowned self] in hostText = $0 })
  private lazy var viewer = ScreenSharingClipboardTransfer(
    send: { [weak self] in self?.viewerChannel.send($0) ?? false },
    read: { [unowned self] in localText }, write: { [unowned self] in viewerText = $0 })

  init(host: ScreenSharingClipboardChannel, viewer: ScreenSharingClipboardChannel) {
    hostChannel = host; viewerChannel = viewer
  }
  func run() async throws {
    defer {
      timeout?.cancel()
      host.onFinished = nil; viewer.onFinished = nil
      host.cancel(); viewer.cancel()
      hostChannel.onMessage = nil; viewerChannel.onMessage = nil
      hostChannel.onAvailabilityChanged = nil; viewerChannel.onAvailabilityChanged = nil
    }
    try await withCheckedThrowingContinuation { continuation in
      completion = continuation
      hostChannel.onMessage = { [weak self] in self?.host.receive($0) }
      viewerChannel.onMessage = { [weak self] in self?.viewer.receive($0) }
      viewer.onFinished = { [weak self] in self?.transferred(error: $0) }
      hostChannel.onAvailabilityChanged = { [weak self] _ in self?.startIfReady() }
      viewerChannel.onAvailabilityChanged = { [weak self] _ in self?.startIfReady() }
      timeout = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        self?.finish(false)
      }
      startIfReady()
    }
  }
  private func startIfReady() {
    guard stage == 0, hostChannel.isAvailable, viewerChannel.isAvailable else { return }
    stage = 1; viewer.sendText(localText)
  }
  private func transferred(error: String?) {
    guard error == nil else { finish(false); return }
    if stage == 1, hostText == localText {
      stage = 2; hostText = remoteText; viewer.requestText()
    } else {
      finish(stage == 2 && viewerText == remoteText)
    }
  }
  private func finish(_ passed: Bool) {
    guard let completion else { return }
    self.completion = nil
    if passed {
      completion.resume()
    } else {
      completion.resume(throwing: ScreenSharingError.unavailable("Clipboard channel check failed."))
    }
  }
}
