import CommonCrypto
import CryptoKit
import Foundation
import Security

public struct ChromeCookieCipher: Sendable {
  private static let service = "Chrome Safe Storage"
  private static let account = "Chrome"
  private static let encryptedPrefix = Data("v10".utf8)
  private static let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)
  private static let domainHashLength = 32
  private static let domainHashVersion = 24

  let key: Data

  public init(password: Data) throws {
    key = try Self.derivedKey(from: password)
  }

  public static func unlock() throws -> ChromeCookieCipher {
    try ChromeCookieCipher(password: safeStoragePassword())
  }

  func value(of encrypted: Data, plain: String, host: String, version: Int) -> String? {
    guard encrypted.starts(with: Self.encryptedPrefix) else { return plain }
    guard let decrypted = decrypt(encrypted.dropFirst(Self.encryptedPrefix.count)) else { return nil }

    let value =
      Self.stripsDomainHash(decrypted, host: host, version: version)
      ? decrypted.dropFirst(Self.domainHashLength) : decrypted
    return String(data: value, encoding: .utf8)
  }

  private func decrypt(_ ciphertext: Data) -> Data? {
    var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
    var written = 0
    let status = output.withUnsafeMutableBytes { out in
      ciphertext.withUnsafeBytes { input in
        key.withUnsafeBytes { key in
          Self.initializationVector.withUnsafeBytes { iv in
            CCCrypt(
              CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
              key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
              out.baseAddress, out.count, &written)
          }
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    return output.prefix(written)
  }

  private static func stripsDomainHash(_ decrypted: Data, host: String, version: Int) -> Bool {
    version >= domainHashVersion && decrypted.count >= domainHashLength
      && decrypted.prefix(domainHashLength) == Data(SHA256.hash(data: Data(host.utf8)))
  }

  private static func safeStoragePassword() throws -> Data {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let password = result as? Data else {
      throw ChromeImportError(keychainStatus: status)
    }
    return password
  }

  private static func derivedKey(from password: Data) throws -> Data {
    let salt = Data("saltysalt".utf8)
    var key = Data(count: kCCKeySizeAES128)
    let status = key.withUnsafeMutableBytes { out in
      password.withUnsafeBytes { password in
        salt.withUnsafeBytes { salt in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), password.bindMemory(to: CChar.self).baseAddress, password.count,
            salt.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003, out.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
        }
      }
    }
    guard status == kCCSuccess else { throw ChromeImportError.unreadable }
    return key
  }
}
