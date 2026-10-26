import AppKit
import Observation

@MainActor
@Observable
final class ChromiumDownloads {
  static let shared = ChromiumDownloads()

  struct Item: Identifiable, Equatable {
    let id: UInt32
    var path: String
    var receivedBytes: Int64
    var totalBytes: Int64
    var state: CVChromiumDownloadState
    var name: String { (path as NSString).lastPathComponent }
    var progress: Double? {
      guard state == .inProgress, totalBytes > 0 else { return nil }
      return min(1, Double(receivedBytes) / Double(totalBytes))
    }
  }

  private(set) var items: [Item] = []
  private(set) var wantsPresentation = false

  var activeProgress: Double? {
    let active = items.filter { $0.state == .inProgress }
    guard !active.isEmpty else { return nil }
    let total = active.reduce(Int64(0)) { $0 + max($1.totalBytes, 0) }
    guard total > 0 else { return 0 }
    return min(1, Double(active.reduce(Int64(0)) { $0 + $1.receivedBytes }) / Double(total))
  }

  private init() {
    CVObserveChromiumDownloads { [weak self] download in
      MainActor.assumeIsolated { self?.update(download) }
    }
  }

  private func update(_ download: CVChromiumDownload) {
    let item = Item(
      id: download.identifier, path: download.path, receivedBytes: download.receivedBytes,
      totalBytes: download.totalBytes, state: download.state)
    let previous = items.firstIndex { $0.id == item.id }
    if item.state == .complete, previous.map({ items[$0].state }) != .complete {
      DistributedNotificationCenter.default().post(
        name: Notification.Name("com.apple.DownloadFileFinished"), object: item.path)
    }
    guard let previous else {
      items.insert(item, at: 0)
      wantsPresentation = true
      return
    }
    items[previous] = item
  }

  func cancel(_ item: Item) { CVCancelChromiumDownload(item.id) }

  func reveal(_ item: Item) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
  }

  func open(_ item: Item) {
    guard item.state == .complete else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
  }

  func presented() { wantsPresentation = false }

  func clearFinished() { items.removeAll { $0.state != .inProgress } }
}
