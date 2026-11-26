import Foundation

public protocol ServerFileCaching: Sendable {
  func cachedFile(machineId: String, fileId: String, preview: Bool) async -> Data?
  func cacheFile(_ data: Data, machineId: String, fileId: String, preview: Bool)
}
