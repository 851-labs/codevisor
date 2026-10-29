import CoreGraphics

enum PlayerConsoleSession {
  private static let lockedKey = "CGSSessionScreenIsLocked"

  static func requireUnlocked() throws {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    guard session?[lockedKey] as? Bool != true else { throw PlayerError.screenLocked }
  }
}
