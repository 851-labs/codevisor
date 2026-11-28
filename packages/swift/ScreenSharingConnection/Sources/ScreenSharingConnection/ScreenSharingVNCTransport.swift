import ScreenSharing
import ScreenSharingV2

@MainActor
public final class ScreenSharingVNCTransport: ScreenSharingTransport {
  public typealias Open = @Sendable () async throws -> (client: RFBClient, outcome: RFBHandshake.Outcome)

  private let openClient: Open
  private let arbitratedByServer: Bool
  private let viewerName: String?
  private let keys: VNCKeyTranslator
  private let scroll: VNCScrollInput
  private var session: VNCScreenSharingSession?

  public var switchesDisplayByReconnecting: Bool { true }

  public init(
    open: @escaping Open, arbitratedByServer: Bool, viewerName: String? = nil,
    keys: VNCKeyTranslator = VNCKeyTranslator(), scroll: VNCScrollInput = .wheel
  ) {
    openClient = open
    self.arbitratedByServer = arbitratedByServer
    self.viewerName = viewerName
    self.keys = keys
    self.scroll = scroll
  }

  public func open(report: @escaping @MainActor (ScreenSharingTransportEvent) -> Void) async throws {
    report(.entered(.connectingMedia))
    let opened: (client: RFBClient, outcome: RFBHandshake.Outcome)
    do {
      opened = try await openClient()
    } catch {
      throw Task.isCancelled ? CancellationError() : Self.end(for: error)
    }
    guard !Task.isCancelled else {
      opened.client.close()
      throw CancellationError()
    }

    let session = VNCScreenSharingSession(
      client: opened.client, parameters: opened.outcome.parameters, keys: keys,
      leaseChannel: arbitratedByServer ? opened.client.controlChannel : nil,
      viewerName: viewerName ?? VNCViewerName.thisDevice, scroll: scroll)
    self.session = session
    report(.opened(session))
    report(.entered(.waitingForVideo))
  }

  public func monitor() async -> ScreenSharingAttemptEnd? {
    guard let session else { return nil }

    let error = await withTaskCancellationHandler {
      await session.outcome()
    } onCancel: {
      Task { @MainActor in session.close() }
    }
    return Task.isCancelled ? nil : Self.end(for: error)
  }

  public func close() {
    session?.close()
    session = nil
  }

  private static func end(for error: any Error) -> ScreenSharingAttemptEnd {
    switch error as? RFBError {
    case .connectionClosed, .transport: .dropped(.networkBlocked)
    default: .refused(.unclassified(message: error.localizedDescription))
    }
  }
}
