import Foundation

/// Small bearer-token HTTP client for rig signaling and control.
public enum RigHTTPClient {
  public struct Failure: Error, CustomStringConvertible {
    public let status: Int
    public let message: String
    public var description: String { "HTTP \(status): \(message)" }
  }

  public static func request(
    _ method: String, _ url: URL, token: String, body: Data? = nil, timeoutSeconds: Double = 10
  ) async throws -> (status: Int, body: Data) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeoutSeconds
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeoutSeconds
    configuration.timeoutIntervalForResource = timeoutSeconds
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (status, data)
  }

  /// POST JSON, decode JSON; non-200 becomes a `Failure` with the server's message.
  public static func post<Request: Encodable, Response: Decodable>(
    _ url: URL, token: String, body: Request, expecting: Response.Type, timeoutSeconds: Double = 10
  ) async throws -> Response {
    let (status, data) = try await request(
      "POST", url, token: token, body: try RigJSON.encode(body), timeoutSeconds: timeoutSeconds)
    guard status == 200 else { throw failure(status, data) }
    return try RigJSON.decode(Response.self, from: data)
  }

  public static func get<Response: Decodable>(
    _ url: URL, token: String, expecting: Response.Type, timeoutSeconds: Double = 10
  ) async throws -> Response {
    let (status, data) = try await request("GET", url, token: token, timeoutSeconds: timeoutSeconds)
    guard status == 200 else { throw failure(status, data) }
    return try RigJSON.decode(Response.self, from: data)
  }

  static func failure(_ status: Int, _ data: Data) -> Failure {
    let message = (try? RigJSON.decode(RigErrorBody.self, from: data))?.error ?? String(decoding: data, as: UTF8.self)
    return Failure(status: status, message: message)
  }
}
