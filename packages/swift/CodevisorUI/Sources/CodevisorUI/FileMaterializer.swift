import CodevisorCore
import CryptoKit
import Foundation

enum FileMaterializer {
  static func url(path: String, client: any CodevisorServerClienting) async throws -> URL {
    if let device = FileDeviceLocation(path) { return device.url }
    let bytes = try await FileDocumentLocation.data(path: path, client: client)
    try Task.checkCancellation()
    return try await write(bytes, named: FileDocumentLocation.name(path))
  }

  @concurrent
  private static func write(_ bytes: Data, named name: String) async throws -> URL {
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let directory = CodevisorAppVariant.temporaryURL().appendingPathComponent("CodevisorFilePreview/\(hash)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent(name)
    try bytes.write(to: target, options: .atomic)
    return target
  }
}
