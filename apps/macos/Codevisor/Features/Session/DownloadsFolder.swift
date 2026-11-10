import Foundation

nonisolated enum DownloadsFolder {
  private static let maxCopies = 10_000
  private static let finishedNotification = Notification.Name("com.apple.DownloadFileFinished")

  static var url: URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
  }

  static func stagingDirectory() throws -> URL {
    try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
  }

  static func place(_ item: URL, isFolder: Bool) throws -> URL {
    for copy in 1...maxCopies {
      let candidate = url.appendingPathComponent(copyName(item.lastPathComponent, copy: copy, isFolder: isFolder))
      do {
        try FileManager.default.moveItem(at: item, to: candidate)
        return candidate
      } catch CocoaError.fileWriteFileExists {
        continue
      }
    }
    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: item.path])
  }

  static func announce(_ item: URL) {
    DistributedNotificationCenter.default().post(name: finishedNotification, object: item.path)
  }

  private static func copyName(_ name: String, copy: Int, isFolder: Bool) -> String {
    guard copy > 1 else { return name }
    let pathExtension = isFolder ? "" : (name as NSString).pathExtension
    guard !pathExtension.isEmpty else { return "\(name) \(copy)" }
    return "\((name as NSString).deletingPathExtension) \(copy).\(pathExtension)"
  }
}
