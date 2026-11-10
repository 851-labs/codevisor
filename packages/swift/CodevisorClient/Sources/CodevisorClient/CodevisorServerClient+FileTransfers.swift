import Foundation

public enum ServerFileConflict: String, Sendable {
  case keepBoth
  case replace
}

extension CodevisorServerClient {
  public func putFile(from fileURL: URL, toPath path: String, conflict: ServerFileConflict) async throws -> String {
    let endpoint = try transferPath(
      "/v1/fs/file", path: path, extra: [URLQueryItem(name: "conflict", value: conflict.rawValue)])
    let response = try await performUpload(
      endpoint, method: "PUT", fileURL: fileURL, contentType: "application/octet-stream")
    return try decoder.decode(PlacedPath.self, from: response).path
  }

  public func createFolder(path: String, conflict: ServerFileConflict) async throws -> String {
    let body = FolderRequest(path: path, conflict: conflict == .keepBoth ? "keepBoth" : nil)
    let placed: PlacedPath = try await send("/v1/fs/mkdir", method: "POST", body: body)
    return placed.path
  }

  public func moveFile(from source: String, to destination: String) async throws -> String {
    let body = MoveRequest(from: source, to: destination)
    let placed: PlacedPath = try await send("/v1/fs/move", method: "POST", body: body)
    return placed.path
  }

  public func deleteFiles(paths: [String]) async throws {
    try await sendNoResponse("/v1/fs/delete", method: "POST", body: DeleteRequest(paths: paths))
  }

  public func workspaceSyncs(workspaceId: UUID) async throws -> [ServerWorkspaceSync] {
    let listed: SyncList = try await get("/v1/workspaces/\(workspaceId.uuidString)/syncs")
    return listed.items
  }

  public func stopWorkspaceSync(workspaceId: UUID, machineId: String) async throws {
    try await sendNoResponse(
      "/v1/workspaces/\(workspaceId.uuidString)/syncs/\(pathComponent(machineId))", method: "DELETE")
  }

  public func remoteExecTasks(workspaceId: UUID) async throws -> [ServerRemoteExecTask] {
    let listed: RemoteTaskList = try await get("/v1/workspaces/\(workspaceId.uuidString)/exec-tasks")
    return listed.items
  }

  public func stopRemoteExecTask(workspaceId: UUID, taskId: String) async throws {
    try await sendNoResponse(
      "/v1/workspaces/\(workspaceId.uuidString)/exec-tasks/\(pathComponent(taskId))/stop", method: "POST")
  }

  public func remoteExecTaskOutput(workspaceId: UUID, taskId: String) async throws -> [String] {
    let output: ServerBackgroundTaskOutput = try await get(
      "/v1/workspaces/\(workspaceId.uuidString)/exec-tasks/\(pathComponent(taskId))/output")
    return output.lines
  }

  public func downloadFile(path: String, to destination: URL) async throws {
    try await performDownload(try transferPath("/v1/fs/file", path: path), to: destination)
  }

  public func downloadArchive(path: String, to destination: URL) async throws {
    try await performDownload(try transferPath("/v1/fs/archive", path: path), to: destination)
  }

  private struct PlacedPath: Decodable {
    let path: String
  }

  private struct RemoteTaskList: Decodable {
    let items: [ServerRemoteExecTask]
  }

  private struct SyncList: Decodable {
    let items: [ServerWorkspaceSync]
  }

  private struct MoveRequest: Encodable {
    let from: String
    let to: String
  }

  private struct DeleteRequest: Encodable {
    let paths: [String]
  }

  private struct FolderRequest: Encodable {
    let path: String
    let conflict: String?
  }

  private func transferPath(_ endpoint: String, path: String, extra: [URLQueryItem] = []) throws -> String {
    var components = URLComponents()
    components.path = endpoint
    components.queryItems = [URLQueryItem(name: "path", value: path)] + extra
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let value = components.string else { throw CodevisorServerClientError.invalidURL(endpoint) }
    return value
  }
}
