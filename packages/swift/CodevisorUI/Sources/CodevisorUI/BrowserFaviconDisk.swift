import CodevisorClient
import Foundation

actor BrowserFaviconDisk {
  static let maximumIcons = 1000
  static let maximumOrigins = 2000

  private let directory: URL
  private let fileManager = FileManager.default
  private var origins: BrowserFaviconOrigins?

  init(directory: URL) {
    self.directory = directory
  }

  func png(_ reference: String) -> Data? {
    let file = iconURL(reference)
    guard let data = try? Data(contentsOf: file) else { return nil }

    touch(file)
    return data
  }

  func store(_ png: Data, reference: String) {
    let file = iconURL(reference)
    guard !fileManager.fileExists(atPath: file.path) else {
      touch(file)
      return
    }

    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try png.write(to: file, options: .atomic)
    } catch {
      Log.persistence.error("Failed to cache a favicon: \(String(describing: error), privacy: .public)")
      return
    }
    trimIcons()
  }

  func originReferences() -> [String: String] {
    loadedOrigins().references
  }

  func record(_ reference: String, origin: String) {
    var index = loadedOrigins()
    index.record(reference, origin: origin, limit: Self.maximumOrigins)
    origins = index
    guard let data = try? JSONEncoder().encode(index) else { return }

    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: originsURL, options: .atomic)
  }

  private var originsURL: URL { directory.appendingPathComponent("origins.json") }

  private func iconURL(_ reference: String) -> URL {
    directory.appendingPathComponent("\(reference).png")
  }

  private func loadedOrigins() -> BrowserFaviconOrigins {
    if let origins { return origins }

    let loaded = storedOrigins() ?? BrowserFaviconOrigins()
    origins = loaded
    return loaded
  }

  private func storedOrigins() -> BrowserFaviconOrigins? {
    guard let data = try? Data(contentsOf: originsURL) else { return nil }

    return try? JSONDecoder().decode(BrowserFaviconOrigins.self, from: data)
  }

  private func touch(_ file: URL) {
    try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
  }

  private func trimIcons() {
    let icons = iconsByAge()
    for file in icons.prefix(max(0, icons.count - Self.maximumIcons)) { try? fileManager.removeItem(at: file) }
  }

  private func iconsByAge() -> [URL] {
    let files =
      (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))
      ?? []
    return files.filter { $0.pathExtension == "png" }.sorted { modified($0) < modified($1) }
  }

  private func modified(_ file: URL) -> Date {
    (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
  }
}
