import Foundation

struct ClientCacheFiles: Sendable {
  let directory: URL

  func write(_ data: Data, named name: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: url(named: name), options: .atomic)
  }

  func read(named name: String) -> Data? {
    try? Data(contentsOf: url(named: name))
  }

  func remove(named names: [String]) {
    for name in names { try? FileManager.default.removeItem(at: url(named: name)) }
  }

  func removeAll() {
    try? FileManager.default.removeItem(at: directory)
  }

  private func url(named name: String) -> URL {
    directory.appendingPathComponent(name, isDirectory: false)
  }
}
