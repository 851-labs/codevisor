import Foundation
import Security

struct KeychainWipe {
  private static var itemClasses: [CFString] {
    [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassCertificate, kSecClassKey, kSecClassIdentity]
  }

  private static let maximumDeletesPerQuery = 256

  let scope: DeviceDataScope.Keychain
  let operations: KeychainOperations

  func run() {
    for query in queries {
      delete(query)
    }
  }

  private var queries: [[String: Any]] {
    switch scope {
    case .everyItem:
      Self.itemClasses.map { [kSecClass as String: $0] }
    case .services(let services):
      services.map { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: $0] }
    }
  }

  private func delete(_ query: [String: Any]) {
    for _ in 0..<Self.maximumDeletesPerQuery {
      let status = operations.delete(query)
      if status == errSecItemNotFound { return }
      guard status == errSecSuccess else { return reportFailure(status) }
    }
  }

  private func reportFailure(_ status: OSStatus) {
    Log.persistence.error("Failed to delete Keychain items: OSStatus \(status, privacy: .public)")
  }
}
