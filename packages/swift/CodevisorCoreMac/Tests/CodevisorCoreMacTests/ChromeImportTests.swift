import CodevisorClient
import CodevisorCoreMac
import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import Testing

@Suite("Chrome sign-in import")
struct ChromeImportTests {
  private let password = Data("fixture-safe-storage".utf8)

  @Test("lists Chrome profiles that have cookies and prefers the last one used")
  func listsProfiles() async throws {
    let root = try ChromeFixture.directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try ChromeFixture.localState(
      in: root, order: ["Default", "Profile 1", "Profile 2"], lastUsed: "Profile 1",
      names: ["Default": "Personal", "Profile 1": "Work", "Profile 2": "Empty"])
    for id in ["Default", "Profile 1"] { try ChromeFixture.cookies(in: root.appending(path: id), rows: []) }

    let found = await ChromeProfiles.load(from: root)

    #expect(found.profiles.map(\.name) == ["Personal", "Work"])
    #expect(found.preferred?.name == "Work")
    #expect(await ChromeProfiles.load(from: root.appending(path: "missing")) == .empty)
  }

  @Test("decrypts current, legacy, and session cookies and skips ones the browser can't use")
  func readsCookies() async throws {
    let root = try ChromeFixture.directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let future = ChromeFixture.chromeTime(Date().addingTimeInterval(86_400))
    let past = ChromeFixture.chromeTime(Date().addingTimeInterval(-86_400))
    try ChromeFixture.cookies(
      in: root,
      rows: [
        .init(
          host: ".github.com", name: "user_session", encrypted: encrypt("signed-in", host: ".github.com"),
          expires: future, updated: 1),
        .init(
          host: ".github.com", name: "user_session", encrypted: encrypt("older", host: ".github.com"), expires: future,
          updated: 0, scheme: 1),
        .init(host: "example.com", name: "legacy", plain: "plain-value", sameSite: 2),
        .init(host: "example.com", name: "expired", encrypted: encrypt("gone", host: "example.com"), expires: past),
        .init(
          host: "example.com", name: "partitioned", encrypted: encrypt("embedded", host: "example.com"),
          partition: "https://other.com"),
      ])

    let cookies = try await ChromeCookieReader.cookies(
      in: ChromeProfile(id: "Default", name: "Personal", directory: root),
      cipher: ChromeCookieCipher(password: password))
    let byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })

    #expect(byName.keys.sorted() == ["legacy", "user_session"])
    #expect(byName["user_session"]?.value == "signed-in")
    #expect(byName["user_session"]?.expires.map { $0 > Date().timeIntervalSince1970 } == true)
    #expect(byName["legacy"]?.value == "plain-value")
    #expect(byName["legacy"]?.expires == nil)
    #expect(byName["legacy"]?.sameSite == "strict")
  }

  private func encrypt(_ value: String, host: String) throws -> Data {
    let plaintext = Data(SHA256.hash(data: Data(host.utf8))) + Data(value.utf8)
    return Data("v10".utf8) + (try ChromeFixture.aes(plaintext, password: password))
  }
}

private struct ChromeFixtureRow {
  var host: String
  var name: String
  var plain = ""
  var encrypted = Data()
  var expires: Int64 = 0
  var updated: Int64 = 0
  var sameSite = -1
  var scheme = 2
  var partition = ""

  init(host: String, name: String, plain: String = "", sameSite: Int = -1) {
    self.host = host
    self.name = name
    self.plain = plain
    self.sameSite = sameSite
  }

  init(
    host: String, name: String, encrypted: Data, expires: Int64 = 0, updated: Int64 = 0, scheme: Int = 2,
    partition: String = ""
  ) {
    self.host = host
    self.name = name
    self.encrypted = encrypted
    self.expires = expires
    self.updated = updated
    self.scheme = scheme
    self.partition = partition
  }
}

private enum ChromeFixture {
  static func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "chrome-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func chromeTime(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
  }

  static func localState(in root: URL, order: [String], lastUsed: String, names: [String: String]) throws {
    let cache = names.mapValues { ["name": $0] }
    let state = ["profile": ["info_cache": cache, "profiles_order": order, "last_used": lastUsed]]
    try JSONSerialization.data(withJSONObject: state).write(to: root.appending(path: "Local State"))
  }

  static func cookies(in directory: URL, rows: [ChromeFixtureRow]) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(directory.appending(path: "Cookies").path, &database) == SQLITE_OK else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close(database) }

    try execute(database, schemaSql)
    for row in rows { try execute(database, insertSql(row)) }
  }

  static func aes(_ plaintext: Data, password: Data) throws -> Data {
    let key = try derivedKey(password)
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var output = Data(count: plaintext.count + kCCBlockSizeAES128)
    var written = 0
    let status = output.withUnsafeMutableBytes { out in
      plaintext.withUnsafeBytes { input in
        key.withUnsafeBytes { key in
          iv.withUnsafeBytes { iv in
            CCCrypt(
              CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
              key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count, out.baseAddress,
              out.count, &written)
          }
        }
      }
    }
    guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
    return output.prefix(written)
  }

  private static func derivedKey(_ password: Data) throws -> Data {
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
    let status = password.withUnsafeBytes { password in
      CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2), password.bindMemory(to: CChar.self).baseAddress, password.count, salt,
        salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
    }
    guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
    return Data(key)
  }

  private static func execute(_ database: OpaquePointer?, _ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
  }

  private static let schemaSql = """
    create table meta(key longvarchar not null unique primary key, value longvarchar);
    insert into meta values ('version', '24');
    create table cookies(creation_utc integer not null, host_key text not null, top_frame_site_key text not null,
      name text not null, value text not null, encrypted_value blob not null, path text not null,
      expires_utc integer not null, is_secure integer not null, is_httponly integer not null,
      last_access_utc integer not null, has_expires integer not null, is_persistent integer not null,
      priority integer not null, samesite integer not null, source_scheme integer not null,
      source_port integer not null, last_update_utc integer not null, source_type integer not null,
      has_cross_site_ancestor integer not null);
    """

  private static func insertSql(_ row: ChromeFixtureRow) -> String {
    let hasExpires = row.expires == 0 ? 0 : 1
    return """
      insert into cookies values (0, '\(row.host)', '\(row.partition)', '\(row.name)', '\(row.plain)',
        x'\(row.encrypted.map { String(format: "%02x", $0) }.joined())', '/', \(row.expires), 1, 1, 0,
        \(hasExpires), \(hasExpires), 1, \(row.sameSite), \(row.scheme), 443, \(row.updated), 0, 0);
      """
  }
}
