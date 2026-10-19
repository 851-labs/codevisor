import ScreenSharing
import ScreenSharingWebRTC
import Foundation

@MainActor
final class ProbeClipboardCheck {
  private let hostChannel: ScreenSharingClipboardChannel
  private let viewerChannel: ScreenSharingClipboardChannel
  private let localText = String(repeating: "Codevisor café 👩🏽‍💻 日本語\n", count: 1000)
  private let remoteText = String(repeating: "Remote ✓ Ελληνικά 한국어\n", count: 1000)
  private let richContent = ScreenSharingClipboardContent(items: [
    [
      .init(
        type: "public.png",
        data: Data((0..<2 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })),
      .init(type: ScreenSharingClipboardContent.textType, data: Data("Screenshot".utf8)),
    ],
    [.init(type: "public.html", data: Data("<b>rich</b>".utf8))],
  ])
  private var hostContent = ScreenSharingClipboardContent(items: [])
  private var viewerContent = ScreenSharingClipboardContent(items: [])
  private var stage = 0
  private var completion: CheckedContinuation<Void, any Error>?
  private var timeout: Task<Void, Never>?
  private lazy var host = ScreenSharingClipboardTransfer(
    send: { [weak self] in self?.hostChannel.send($0) ?? false },
    canReceiveUnsolicited: { true }, read: { [unowned self] _ in hostContent },
    write: { [unowned self] in hostContent = $0 })
  private lazy var viewer = ScreenSharingClipboardTransfer(
    send: { [weak self] in self?.viewerChannel.send($0) ?? false },
    read: { [unowned self] _ in .init(text: localText) }, write: { [unowned self] in viewerContent = $0 })

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
    stage = 1; viewer.sendContent(.init(text: localText))
  }
  private func transferred(error: String?) {
    guard error == nil else { finish(false); return }
    switch stage {
    case 1 where hostContent.text == localText:
      stage = 2; hostContent = .init(text: remoteText); viewer.requestContent()
    case 2 where viewerContent.text == remoteText:
      stage = 3; host.richContent = true; viewer.richContent = true
      viewer.sendContent(richContent)
    default:
      finish(stage == 3 && hostContent == richContent)
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
