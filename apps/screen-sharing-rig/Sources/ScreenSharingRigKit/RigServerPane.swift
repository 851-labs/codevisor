import Foundation

/// The Screen Sharing pane the rig views a Codevisor server's native display
/// through (851-2384). The server starts a native session only for a real
/// Screen Sharing pane in one of its workspaces, as the app has; the rig keeps
/// one of its own there: a scratch project, a "Screen Sharing Rig" workspace
/// and its pane. The ids are fixed, and every request is an idempotent
/// create-or-update, so each connect converges on the same three records.
public enum RigServerPane {
  public static let projectId = UUID(uuidString: "5C2E1A7B-0D3F-4B8E-9A61-7E4C2B1D9F01")!
  public static let workspaceId = UUID(uuidString: "5C2E1A7B-0D3F-4B8E-9A61-7E4C2B1D9F02")!
  public static let paneId = UUID(uuidString: "5C2E1A7B-0D3F-4B8E-9A61-7E4C2B1D9F03")!

  public struct Request: Equatable, Sendable {
    public var method: String
    public var path: String
    /// The JSON body.
    public var body: String
  }

  /// In order: the project, its workspace, then the pane.
  public static let requests: [Request] = [
    Request(method: "POST", path: "/v1/projects/scratch", body: #"{"id":"\#(projectId.uuidString)"}"#),
    Request(
      method: "PUT", path: "/v1/workspaces/\(workspaceId.uuidString)",
      body:
        #"{"hasCustomName":true,"id":"\#(workspaceId.uuidString)","name":"Screen Sharing Rig","projectId":"\#(projectId.uuidString)"}"#
    ),
    Request(
      method: "PUT", path: "/v1/workspaces/\(workspaceId.uuidString)/panes/\(paneId.uuidString)",
      body:
        #"{"id":"\#(paneId.uuidString)","metadata":"{\"schemaVersion\":1}","paneType":"screen-sharing","providerId":"codevisor","title":"Screen Sharing Rig"}"#
    ),
  ]

  public struct Failure: LocalizedError, Equatable {
    public let errorDescription: String?
  }

  /// Sends `requests` to the server at `baseURL`; throws on the first non-2xx answer.
  public static func ensure(
    baseURL: URL, token: String,
    send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
  ) async throws {
    for step in requests {
      var request = URLRequest(url: baseURL.appending(path: step.path))
      request.httpMethod = step.method
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(step.body.utf8)
      let (_, response) = try await send(request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else {
        throw Failure(
          errorDescription: "The server refused the rig's Screen Sharing pane (\(step.method) \(step.path): \(status))."
        )
      }
    }
  }
}
