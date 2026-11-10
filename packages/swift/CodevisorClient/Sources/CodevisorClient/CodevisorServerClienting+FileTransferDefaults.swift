import Foundation

public extension CodevisorServerClienting {
  func putFile(from fileURL: URL, toPath path: String, conflict: ServerFileConflict) async throws -> String {
    throw CodevisorServerClientError.invalidResponse
  }

  func createFolder(path: String, conflict: ServerFileConflict) async throws -> String {
    throw CodevisorServerClientError.invalidResponse
  }

  func moveFile(from source: String, to destination: String) async throws -> String {
    throw CodevisorServerClientError.invalidResponse
  }

  func deleteFiles(paths: [String]) async throws {
    throw CodevisorServerClientError.invalidResponse
  }

  func downloadFile(path: String, to destination: URL) async throws {
    throw CodevisorServerClientError.invalidResponse
  }

  func downloadArchive(path: String, to destination: URL) async throws {
    throw CodevisorServerClientError.invalidResponse
  }
}
