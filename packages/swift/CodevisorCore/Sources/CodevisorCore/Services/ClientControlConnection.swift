import Foundation

/// One window's authenticated control channel. Uses the same transport seams
/// as sessions, including cloud relay. No navigation is retried or replayed.
@MainActor
public enum ClientControlConnection {
  public typealias ContextReader = @MainActor () -> NativeClientContext
  public typealias Navigator = @MainActor (ClientNavigationRequest) async throws -> Void
  public typealias Controller = @MainActor (ClientUIAction) async throws -> Void

  struct Command: Decodable {
    let requestId: String
    let method: String
    var navigation: ClientNavigationRequest?
    var page: ClientPageRequest?
    var layout: ClientLayoutRequest?
    var window: ClientWindowRequest?
  }
  struct Response: Encodable {
    var type = "response"
    let requestId: String
    var context: NativeClientContext?
    var error: String?
  }

  public static func run(
    clientId: UUID,
    name: String,
    platform: String,
    config: CodevisorServerConfig,
    context: @escaping ContextReader,
    navigate: @escaping Navigator,
    control: @escaping Controller = { _ in throw ClientControlError("UI control is unavailable") }
  ) async {
    guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
      return
    }
    components.scheme = config.baseURL.scheme == "https" ? "wss" : "ws"
    components.path = "/v1/clients/\(clientId.uuidString.lowercased())/socket"
    components.query = nil
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    if let token = config.bearerToken, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let transport = config.webSocketTransport ?? URLSessionWebSocketTransport()
    while !Task.isCancelled {
      let socket = transport.connect(request, maximumMessageSize: 2 * 1024 * 1024)
      await withTaskCancellationHandler {
        defer { socket.cancel(with: .goingAway, reason: nil) }
        do {
          let hello = ["type": "hello", "name": name, "platform": platform]
          try await socket.send(.data(JSONEncoder().encode(hello)))
          while !Task.isCancelled {
            let data: Data
            switch try await socket.receive() {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            }
            let command = try JSONDecoder().decode(Command.self, from: data)
            let response = await handle(command, context: context, navigate: navigate, control: control)
            try Task.checkCancellation()
            try await socket.send(.data(JSONEncoder().encode(response)))
          }
        } catch {
          // A lost channel has no durable command queue. Re-register only;
          // the caller receives a disconnect/timeout from the server.
        }
      } onCancel: {
        socket.cancel(with: .goingAway, reason: nil)
      }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }

  static func handle(
    _ command: Command,
    context: ContextReader,
    navigate: Navigator,
    control: Controller = { _ in throw ClientControlError("UI control is unavailable") }
  ) async -> Response {
    do {
      try Task.checkCancellation()
      switch command.method {
      case "context": break
      case "navigate":
        guard let request = command.navigation else {
          throw ClientControlError("Missing navigation request")
        }
        try await navigate(request)
      case "page":
        guard let request = command.page else { throw ClientControlError("Missing page request") }
        try await control(.page(request))
      case "layout":
        guard let request = command.layout else { throw ClientControlError("Missing layout request") }
        try await control(.layout(request))
      case "window":
        guard let request = command.window else { throw ClientControlError("Missing window request") }
        try await control(.window(request))
      default: throw ClientControlError("Unknown client command")
      }
      return Response(requestId: command.requestId, context: context())
    } catch {
      return Response(requestId: command.requestId, error: error.localizedDescription)
    }
  }
}
