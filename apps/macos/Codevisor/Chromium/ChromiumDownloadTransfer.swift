import Foundation

nonisolated enum ChromiumDownloadTransfer {
  private static let chunkBytes = 512 * 1024

  @concurrent
  static func send(
    _ download: ChromiumAutomationDownload, guid: String, through connection: ChromiumAutomationConnection
  ) async {
    do {
      try await sendFile(download, guid: guid, through: connection)
      await connection.send(encoded(download.progress(guid: guid, state: .completed)))
    } catch {
      await connection.send(encoded(download.progress(guid: guid, state: .canceled)))
    }
  }

  private static func sendFile(
    _ download: ChromiumAutomationDownload, guid: String, through connection: ChromiumAutomationConnection
  ) async throws {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: download.path))
    defer { try? handle.close() }
    while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
      await connection.send(encoded(download.data(guid: guid, chunk: chunk)))
    }
  }

  private static func encoded(_ message: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)
  }
}
