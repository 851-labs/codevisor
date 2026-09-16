import CodevisorCore
import Observation
import SwiftUI

/// Directory listings and filename search for one workspace root. The
/// platform browsers (a quick-open picker on Mac, folder pages on iPhone)
/// read listings from here and search on the machine that owns the files.
@MainActor @Observable
final class FileExplorerModel {
  let root: String
  var listings: [String: [ServerFileEntry]] = [:]
  var loading: Set<String> = []
  var errors: [String: String] = [:]
  private let client: any CodevisorServerClienting

  init(root: String, client: any CodevisorServerClienting) {
    self.root = root
    self.client = client
  }

  var rootName: String { (root as NSString).lastPathComponent }

  func relativePath(_ path: String) -> String {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard path.hasPrefix(prefix) else { return path }
    return String(path.dropFirst(prefix.count))
  }

  func searchFiles(in directory: String, query: String) async throws -> ServerFileSearch {
    try await client.searchFileEntries(path: directory, query: query)
  }

  func load(_ path: String) async {
    guard !loading.contains(path) else { return }
    loading.insert(path)
    defer { loading.remove(path) }
    do {
      listings[path] = try await client.fileEntries(path: path, showHidden: true).entries
      errors[path] = nil
    } catch {
      if !isTaskCancellation(error) { errors[path] = serverErrorMessage(error) }
    }
  }
}
