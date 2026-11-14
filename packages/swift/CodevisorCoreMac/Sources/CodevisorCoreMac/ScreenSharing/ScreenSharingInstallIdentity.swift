import Foundation

enum ScreenSharingInstallIdentity {
  private static let groups = [8, 4, 4, 4, 12]

  static func id(forKey key: String) throws -> UUID {
    var digits = Substring(key)
    let text = groups.map { length in
      defer { digits = digits.dropFirst(length) }
      return digits.prefix(length)
    }
    guard let id = UUID(uuidString: text.joined(separator: "-")) else { throw CocoaError(.coderInvalidValue) }

    return id
  }
}
