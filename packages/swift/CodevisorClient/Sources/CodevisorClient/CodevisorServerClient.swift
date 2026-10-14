import ACPKit
import CodevisorProtocol
import Foundation

public enum CodevisorServerClientError: Error, Equatable, Sendable, LocalizedError {
  case invalidURL(String)
  case invalidResponse
  case httpStatus(Int, String)
  case invalidDate(String)
  case invalidUUID(String)

  public var errorDescription: String? {
    switch self {
    case let .invalidURL(url):
      "The server address “\(url)” isn't valid."
    case .invalidResponse:
      "The Codevisor server sent an unexpected response. Try again in a moment."
    case let .httpStatus(_, body):
      body.isEmpty ? "The Codevisor server rejected the request." : serverErrorMessage(body) ?? body
    case .invalidDate, .invalidUUID:
      "The Codevisor server sent data this version of Codevisor couldn't read. Updating Codevisor may fix this."
    }
  }
}

func serverErrorMessage(_ body: String) -> String? {
  guard let data = body.data(using: .utf8),
    let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let message = payload["error"] as? String, !message.isEmpty
  else { return nil }
  return message
}

public func serverErrorCode(_ error: any Error) -> String? {
  guard case let CodevisorServerClientError.httpStatus(_, body) = error,
    let data = body.data(using: .utf8),
    let payload = try? JSONDecoder().decode([String: String?].self, from: data)
  else { return nil }
  return payload["code"] ?? nil
}

public let serverUnreachableErrorMessage = "Can't connect to the Codevisor server."

public func isTaskCancellation(_ error: any Error) -> Bool {
  if error is CancellationError { return true }
  if let urlError = error as? URLError, urlError.code == .cancelled { return true }
  return false
}

public func serverErrorMessage(_ error: any Error) -> String {
  if case let CodevisorServerClientError.httpStatus(_, body) = error {
    if let data = body.data(using: .utf8),
      let payload = try? JSONDecoder().decode([String: String].self, from: data),
      let message = payload["error"]
    {
      return message
    }
    return body.isEmpty ? "The Codevisor server rejected the request." : body
  }
  if let urlError = error as? URLError {
    switch urlError.code {
    case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
      .timedOut, .secureConnectionFailed, .cannotLoadFromNetwork:
      return serverUnreachableErrorMessage
    case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
      return "You appear to be offline. Check your network connection, then try again."
    default:
      return urlError.localizedDescription
    }
  }
  if let localized = error as? LocalizedError, let description = localized.errorDescription {
    return description
  }
  let nsError = error as NSError
  if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSURLErrorDomain
    || nsError.domain == NSPOSIXErrorDomain
  {
    return nsError.localizedDescription
  }
  return String(describing: error)
}

public struct CodevisorServerConfig: Equatable, Sendable {
  public static let productionPort = CodevisorAppVariant.productionPort
  public static let developmentPort = CodevisorAppVariant.developmentPort

  public static var localPort: Int {
    CodevisorAppVariant.localServerPort
  }

  public var baseURL: URL
  public var bearerToken: String?
  public var requestTransport: (any ServerRequestTransport)?
  public var webSocketTransport: (any ServerWebSocketTransport)?

  public init(
    baseURL: URL = URL(string: "http://127.0.0.1:\(CodevisorServerConfig.localPort)")!,
    bearerToken: String? = nil,
    requestTransport: (any ServerRequestTransport)? = nil,
    webSocketTransport: (any ServerWebSocketTransport)? = nil
  ) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
    self.requestTransport = requestTransport
    self.webSocketTransport = webSocketTransport
  }

  public static func == (lhs: CodevisorServerConfig, rhs: CodevisorServerConfig) -> Bool {
    lhs.baseURL == rhs.baseURL && lhs.bearerToken == rhs.bearerToken
  }

  public static let localDefault = CodevisorServerConfig()
}

public final class CodevisorServerClient: CodevisorServerClienting, @unchecked Sendable {
  static let eventWebSocketMaximumMessageSize = 16 * 1024 * 1024
  static let requestGateTimeout: Duration = .seconds(60)
  let config: CodevisorServerConfig
  let requestTransport: any ServerRequestTransport
  let webSocketTransport: any ServerWebSocketTransport
  let requestGate: ServerRequestGate?
  let machineId: String?
  let decoder = JSONDecoder()
  let encoder = JSONEncoder()
  let eventSleep: @Sendable (Duration) async throws -> Void

  public init(
    config: CodevisorServerConfig = .localDefault,
    urlSession: URLSession = .shared,
    requestGate: ServerRequestGate? = nil,
    machineId: String? = nil,
    eventSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.config = config
    self.requestTransport =
      config.requestTransport
      ?? URLSessionRequestTransport(session: urlSession)
    self.webSocketTransport =
      config.webSocketTransport
      ?? URLSessionWebSocketTransport(session: urlSession)
    self.requestGate = requestGate
    self.machineId = machineId
    self.eventSleep = eventSleep
  }

  func harnessAccountsPath(_ harnessId: String) -> String {
    "/v1/harnesses/\(pathComponent(harnessId))/accounts"
  }

  func harnessAccountPath(_ harnessId: String, _ accountId: String) -> String {
    "\(harnessAccountsPath(harnessId))/\(pathComponent(accountId))"
  }

  func openCodeProvidersPath(_ accountId: String) -> String {
    "/v1/harnesses/opencode/accounts/\(pathComponent(accountId))/providers"
  }

  func pathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  func get<Response: Decodable>(_ path: String) async throws -> Response {
    try await send(path, method: "GET", body: Optional<EmptyBody>.none)
  }

  func send<Response: Decodable, Body: Encodable>(
    _ path: String,
    method: String,
    body: Body?,
    timeout: TimeInterval? = nil
  ) async throws -> Response {
    let data = try await perform(path, method: method, body: body, timeout: timeout)
    return try decoder.decode(Response.self, from: data)
  }

  func sendNoResponse(_ path: String, method: String) async throws {
    try await sendNoResponse(path, method: method, body: Optional<EmptyBody>.none)
  }

  func sendNoResponse<Body: Encodable>(
    _ path: String,
    method: String,
    body: Body?
  ) async throws {
    _ = try await perform(path, method: method, body: body)
  }

  @discardableResult
  func perform<Body: Encodable>(
    _ path: String,
    method: String,
    body: Body?,
    timeout: TimeInterval? = nil
  ) async throws -> Data {
    try await waitForServerIfNeeded(path: path)
    let request = try makeJSONRequest(path, method: method, body: body, timeout: timeout)

    let (data, httpResponse) = try await requestTransport.data(for: request)
    try validateResponse(data, httpResponse)
    return data
  }

  func performRaw(
    _ path: String,
    method: String,
    body: Data?,
    contentType: String?
  ) async throws -> Data {
    let (data, _) = try await performRawResponse(
      path,
      method: method,
      body: body,
      contentType: contentType
    )
    return data
  }

  func performRawResponse(
    _ path: String,
    method: String,
    body: Data?,
    contentType: String?
  ) async throws -> (Data, HTTPURLResponse) {
    try await waitForServerIfNeeded(path: path)
    let request = try makeRawRequest(path, method: method, body: body, contentType: contentType)

    let (data, httpResponse) = try await requestTransport.data(for: request)
    try validateResponse(data, httpResponse)
    return (data, httpResponse)
  }

  func performUpload(
    _ path: String,
    fileURL: URL,
    contentType: String
  ) async throws -> Data {
    try await waitForServerIfNeeded(path: path)
    let request = try makeUploadRequest(path, contentType: contentType)

    let (data, httpResponse) = try await requestTransport.upload(for: request, fromFile: fileURL)
    try validateResponse(data, httpResponse)
    return data
  }

  private func makeJSONRequest<Body: Encodable>(
    _ path: String, method: String, body: Body?, timeout: TimeInterval?
  ) throws -> URLRequest {
    var request = URLRequest(url: try url(for: path))
    request.httpMethod = method
    if let timeout {
      request.timeoutInterval = timeout
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyAuthorization(to: &request)
    if let body {
      request.httpBody = try encoder.encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private func makeRawRequest(
    _ path: String, method: String, body: Data?, contentType: String?
  ) throws -> URLRequest {
    var request = URLRequest(url: try url(for: path))
    request.httpMethod = method
    applyAuthorization(to: &request)
    if let body {
      request.httpBody = body
    }
    if let contentType {
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private func makeUploadRequest(_ path: String, contentType: String) throws -> URLRequest {
    var request = URLRequest(url: try url(for: path))
    request.httpMethod = "POST"
    applyAuthorization(to: &request)
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    return request
  }

  private func validateResponse(_ data: Data, _ httpResponse: HTTPURLResponse) throws {
    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? ""
      throw CodevisorServerClientError.httpStatus(httpResponse.statusCode, message)
    }
  }

  func waitForServerIfNeeded(path: String) async throws {
    guard !Self.isLifecyclePath(path), let requestGate, let machineId else { return }
    #if DEBUG || NAVIGATION_DIAGNOSTICS
      Log.cloud.notice(
        "CLOUDRELAYDBG request.gate.begin machine=\(machineId, privacy: .public) path=\(path, privacy: .public)"
      )
    #endif
    try await requestGate.waitUntilReady(
      for: machineId,
      timeout: Self.requestGateTimeout
    )
    #if DEBUG || NAVIGATION_DIAGNOSTICS
      Log.cloud.notice(
        "CLOUDRELAYDBG request.gate.end machine=\(machineId, privacy: .public) path=\(path, privacy: .public)"
      )
    #endif
  }

  private static func isLifecyclePath(_ path: String) -> Bool {
    path == "/v1/health"
      || path == "/v1/info"
      || path == "/v1/shutdown"
      || path.hasPrefix("/v1/update")
      || path.hasPrefix("/v1/restart")
  }

  func applyAuthorization(to request: inout URLRequest) {
    guard let bearerToken = config.bearerToken else { return }
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
  }

  func url(for path: String) throws -> URL {
    let trimmedBase = config.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(trimmedBase)\(path)") else {
      throw CodevisorServerClientError.invalidURL(path)
    }
    return url
  }

  func websocketURL(for path: String) throws -> URL {
    let baseURL = try url(for: path)
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw CodevisorServerClientError.invalidURL(path)
    }
    switch components.scheme {
    case "http":
      components.scheme = "ws"
    case "https":
      components.scheme = "wss"
    default:
      break
    }
    guard let url = components.url else {
      throw CodevisorServerClientError.invalidURL(path)
    }
    return url
  }
}

struct EmptyBody: Encodable {}
