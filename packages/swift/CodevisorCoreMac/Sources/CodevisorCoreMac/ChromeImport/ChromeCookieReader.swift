import CodevisorClient
import Foundation

public enum ChromeCookieReader {
  private static let unixEpochOffset: Double = 11_644_473_600
  private static let microseconds: Double = 1_000_000
  private static let sameSites = [-1: "unspecified", 0: "none", 1: "lax", 2: "strict"]
  private static let databaseFiles = ["Cookies", "Cookies-journal", "Cookies-wal"]
  private static let cookiesSql = """
    select host_key, name, value, encrypted_value, path, expires_utc, has_expires, is_secure,
      is_httponly, samesite, last_update_utc
    from cookies where top_frame_site_key = ''
    """
  private static let versionSql = "select value from meta where key = 'version'"

  @concurrent
  public static func cookies(in profile: ChromeProfile, cipher: ChromeCookieCipher) async throws -> [BrowserCookie] {
    let copy = try snapshot(of: profile.directory)
    defer { try? FileManager.default.removeItem(at: copy) }

    let database = try ChromeCookieDatabase(url: copy.appending(path: "Cookies"))
    let version = Int(database.strings(versionSql).first ?? "") ?? 0
    let now = Date().timeIntervalSince1970
    let rows = database.rows(cookiesSql).compactMap { cookie(from: $0, cipher: cipher, version: version, now: now) }
    return latestByKey(rows)
  }

  private static func snapshot(of directory: URL) throws -> URL {
    let copy = FileManager.default.temporaryDirectory.appending(path: "chrome-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    for name in databaseFiles where FileManager.default.fileExists(atPath: directory.appending(path: name).path) {
      try FileManager.default.copyItem(at: directory.appending(path: name), to: copy.appending(path: name))
    }
    return copy
  }

  private static func cookie(
    from row: ChromeCookieRow, cipher: ChromeCookieCipher, version: Int, now: TimeInterval
  ) -> (cookie: BrowserCookie, updated: Int64)? {
    let expires = row.hasExpires ? Double(row.expiresUTC) / microseconds - unixEpochOffset : nil
    if let expires, expires <= now { return nil }
    guard !row.name.isEmpty,
      let value = cipher.value(of: row.encryptedValue, plain: row.value, host: row.host, version: version)
    else { return nil }

    let cookie = BrowserCookie(
      name: row.name, value: value, domain: row.host, path: row.path, secure: row.secure,
      httpOnly: row.httpOnly, sameSite: sameSites[row.sameSite] ?? "unspecified", expires: expires)
    return (cookie, row.lastUpdateUTC)
  }

  private static func latestByKey(_ rows: [(cookie: BrowserCookie, updated: Int64)]) -> [BrowserCookie] {
    let latest = Dictionary(rows.map { ($0.cookie.key, $0) }) { first, second in
      first.updated >= second.updated ? first : second
    }
    return latest.values.map(\.cookie)
  }
}
