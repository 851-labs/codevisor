import Foundation

public struct ComposerAttachmentFileStore: Sendable, Equatable {
  public let root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  public static func temporary() -> ComposerAttachmentFileStore {
    ComposerAttachmentFileStore(
      root: FileManager.default.temporaryDirectory
        .appendingPathComponent("CodevisorComposerAttachments-\(UUID().uuidString)", isDirectory: true)
    )
  }

  public func stageCopy(of source: URL, id: UUID, name: String) throws -> URL {
    let destination = try prepareDestination(id: id, name: name)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  public func stage(data: Data, id: UUID, name: String) throws -> URL {
    let destination = try prepareDestination(id: id, name: name)
    try data.write(to: destination, options: .atomic)
    return destination
  }

  public func remove(id: UUID) {
    try? FileManager.default.removeItem(at: directory(for: id))
  }

  public func removeAll(except keep: Set<UUID>, createdBefore cutoff: Date) {
    let keys: [URLResourceKey] = [.creationDateKey]
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return }
    for entry in entries {
      if let id = UUID(uuidString: entry.lastPathComponent), keep.contains(id) { continue }
      let created = (try? entry.resourceValues(forKeys: Set(keys)))?.creationDate ?? .distantPast
      guard created <= cutoff else { continue }
      try? FileManager.default.removeItem(at: entry)
    }
  }

  public func relativePath(of fileURL: URL) -> String? {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    let path = fileURL.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else { return nil }
    return String(path.dropFirst(rootPath.count))
  }

  public func fileURL(forRelativePath relativePath: String) -> URL? {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count == 2, UUID(uuidString: String(components[0])) != nil,
      !components[1].isEmpty, components[1] != "..", components[1] != "."
    else { return nil }
    return
      root
      .appendingPathComponent(String(components[0]), isDirectory: true)
      .appendingPathComponent(String(components[1]), isDirectory: false)
  }

  public static func byteCount(of fileURL: URL) -> Int? {
    guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
    else { return nil }
    return size.intValue
  }

  private func directory(for id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  private func prepareDestination(id: UUID, name: String) throws -> URL {
    let directory = directory(for: id)
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: directory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(Self.safeFilename(name), isDirectory: false)
  }

  static func safeFilename(_ name: String) -> String {
    let cleaned = String(
      name.unicodeScalars.map { scalar -> Character in
        scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar)
          ? "_" : Character(scalar)
      }
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "attachment" }
    return String(cleaned.prefix(200))
  }
}
