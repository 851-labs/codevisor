import Foundation

struct ChromeCookieRow {
  let host: String
  let name: String
  let value: String
  let encryptedValue: Data
  let path: String
  let expiresUTC: Int64
  let hasExpires: Bool
  let secure: Bool
  let httpOnly: Bool
  let sameSite: Int
  let lastUpdateUTC: Int64
}
