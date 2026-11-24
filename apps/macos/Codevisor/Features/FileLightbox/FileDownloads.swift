import CodevisorUI
import Foundation
import Observation

@Observable
final class FileDownloads {
  enum Phase: Equatable {
    case downloading
    case finished(URL)
    case failed(String)
  }

  struct Download: Identifiable, Equatable {
    let id: UUID
    let name: String
    var phase: Phase
  }

  static let shared = FileDownloads()

  private(set) var downloads: [Download] = []

  private static let finishedLinger: Duration = .seconds(5)
  private static let failedLinger: Duration = .seconds(10)

  func phase(of name: String) -> Phase? {
    downloads.last { $0.name == name }?.phase
  }

  func download(_ id: Download.ID) -> Download? {
    downloads.first { $0.id == id }
  }

  @discardableResult
  func start(_ item: FileTransferItem) -> Download? {
    guard phase(of: item.name) != .downloading else { return nil }

    let download = Download(id: UUID(), name: item.name, phase: .downloading)
    downloads.append(download)
    Task { await run(download, loading: item) }
    return download
  }

  func dismiss(_ id: UUID) {
    downloads.removeAll { $0.id == id }
  }

  private func run(_ download: Download, loading item: FileTransferItem) async {
    do {
      let saved = try await Self.saveToDownloads(item)
      DownloadsFolder.announce(saved)
      await settle(download.id, as: .finished(saved), lingering: Self.finishedLinger)
    } catch {
      await settle(download.id, as: .failed(error.localizedDescription), lingering: Self.failedLinger)
    }
  }

  private func settle(_ id: UUID, as phase: Phase, lingering linger: Duration) async {
    guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }

    downloads[index].phase = phase
    try? await Task.sleep(for: linger)
    dismiss(id)
  }

  @concurrent
  private nonisolated static func saveToDownloads(_ item: FileTransferItem) async throws -> URL {
    let staging = try DownloadsFolder.stagingDirectory()
    defer { try? FileManager.default.removeItem(at: staging) }
    let name = (item.name as NSString).lastPathComponent
    let staged = staging.appendingPathComponent(name.isEmpty ? "Attachment" : name)
    try await item.load().write(to: staged, options: .atomic)
    return try DownloadsFolder.place(staged, isFolder: false)
  }
}
