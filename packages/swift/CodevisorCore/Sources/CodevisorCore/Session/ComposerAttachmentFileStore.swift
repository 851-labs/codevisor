import Foundation

/// The app-owned directory composer attachments are staged in, one
/// subdirectory per attachment id (`<root>/<id>/<name>`). Uploads, retries,
/// machine retargets, and persisted drafts all read the staged file, so an
/// attachment's bytes never have to sit in memory. File URLs are copied in
/// with `FileManager.copyItem`, which clones on APFS.
public struct ComposerAttachmentFileStore: Sendable, Equatable {
  public let root: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
  }

  /// A private directory under the temporary folder, for tests, previews,
  /// and controllers that were not handed the app's store.
  public static func temporary() -> ComposerAttachmentFileStore {
    ComposerAttachmentFileStore(
      root: FileManager.default.temporaryDirectory
        .appendingPathComponent("CodevisorComposerAttachments-\(UUID().uuidString)", isDirectory: true)
    )
  }

  /// Copies `source` into the attachment's directory, replacing anything
  /// staged for `id` before.
  public func stageCopy(of source: URL, id: UUID, name: String) throws -> URL {
    let destination = try prepareDestination(id: id, name: name)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  /// Writes in-memory bytes (a pasted image) as the attachment's file.
  public func stage(data: Data, id: UUID, name: String) throws -> URL {
    let destination = try prepareDestination(id: id, name: name)
    try data.write(to: destination, options: .atomic)
    return destination
  }

  /// Deletes everything staged for `id`.
  public func remove(id: UUID) {
    try? FileManager.default.removeItem(at: directory(for: id))
  }

  /// Deletes staged attachments that no draft references. Only directories
  /// created before `cutoff` qualify, so an attachment staged while the
  /// sweep runs is never collected.
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

  /// The staged file's path relative to `root` ("<id>/<name>"), which is
  /// what drafts persist: iOS moves the app container between launches, so
  /// an absolute path would not survive.
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

  /// The file's size from its attributes, without reading it.
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

  /// Keeps the display name (and its extension, which later type checks
  /// read) while making sure it stays one path component.
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
