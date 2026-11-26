import CodevisorClient
import Foundation
import ScreenSharing

final class LinuxDesktopRelaySocket: ServerWebSocketConnecting, @unchecked Sendable {
  private let desktop: RFBNetworkTransport
  private let onViewerText: @Sendable (String) -> Void
  private let inbound: AsyncStream<ServerWebSocketMessage>
  private let deliver: AsyncStream<ServerWebSocketMessage>.Continuation
  private var pump: Task<Void, Never>?

  let closeCode: URLSessionWebSocketTask.CloseCode = .invalid

  init(desktop: RFBNetworkTransport, onViewerText: @escaping @Sendable (String) -> Void) {
    self.desktop = desktop
    self.onViewerText = onViewerText
    (inbound, deliver) = AsyncStream.makeStream()
    pump = Task { [desktop, deliver] in
      while let bytes = try? await desktop.read(maximum: 1 << 16), !bytes.isEmpty {
        deliver.yield(.data(Data(bytes)))
      }
      deliver.finish()
    }
  }

  func send(_ message: ServerWebSocketMessage) async throws {
    switch message {
    case .data(let data): try await desktop.write([UInt8](data))
    case .string(let text): onViewerText(text)
    @unknown default: break
    }
  }

  func receive() async throws -> ServerWebSocketMessage {
    for await message in inbound { return message }
    throw URLError(.networkConnectionLost)
  }

  func sendToViewer(_ text: String) {
    deliver.yield(.string(text))
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    pump?.cancel()
    desktop.close()
    deliver.finish()
  }
}
