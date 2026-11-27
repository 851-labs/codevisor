import Foundation

public protocol ServerFileCaching: Sendable {
  func cacheFile(_ data: Data, machineId: String, fileId: String, preview: Bool)
}
