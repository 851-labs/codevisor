@testable import CodevisorClient
import Foundation
import Security

final class DeviceDataKeychain: @unchecked Sendable {
  private struct Item: Hashable {
    let itemClass: String
    let service: String
    let account: String
  }

  private let lock = NSLock()
  private let deletesOneMatchPerCall: Bool
  private var items: [Item: Data] = [:]

  init(deletesOneMatchPerCall: Bool = false) {
    self.deletesOneMatchPerCall = deletesOneMatchPerCall
  }

  var isEmpty: Bool {
    lock.withLock { items.isEmpty }
  }

  var operations: KeychainOperations {
    KeychainOperations(
      copyMatching: { [self] query in copy(query) },
      update: { [self] query, attributes in update(query, attributes) },
      add: { [self] attributes in add(attributes) },
      delete: { [self] query in delete(query) }
    )
  }

  private func copy(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
    lock.withLock {
      guard let data = items[item(query)] else { return (errSecItemNotFound, nil) }
      return (errSecSuccess, data)
    }
  }

  private func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
    lock.withLock {
      let key = item(query)
      guard items[key] != nil else { return errSecItemNotFound }
      items[key] = attributes[kSecValueData as String] as? Data
      return errSecSuccess
    }
  }

  private func add(_ attributes: [String: Any]) -> OSStatus {
    lock.withLock {
      let key = item(attributes)
      guard items[key] == nil else { return errSecDuplicateItem }
      items[key] = attributes[kSecValueData as String] as? Data ?? Data()
      return errSecSuccess
    }
  }

  private func delete(_ query: [String: Any]) -> OSStatus {
    lock.withLock {
      let matching = items.keys.filter { matches($0, query) }
      guard !matching.isEmpty else { return errSecItemNotFound }
      for key in deletesOneMatchPerCall ? Array(matching.prefix(1)) : matching { items[key] = nil }
      return errSecSuccess
    }
  }

  private func matches(_ item: Item, _ query: [String: Any]) -> Bool {
    let wanted = self.item(query)
    return wanted.itemClass == item.itemClass
      && (query[kSecAttrService as String] == nil || wanted.service == item.service)
      && (query[kSecAttrAccount as String] == nil || wanted.account == item.account)
  }

  private func item(_ query: [String: Any]) -> Item {
    Item(
      itemClass: query[kSecClass as String] as? String ?? "",
      service: query[kSecAttrService as String] as? String ?? "",
      account: query[kSecAttrAccount as String] as? String ?? ""
    )
  }
}
