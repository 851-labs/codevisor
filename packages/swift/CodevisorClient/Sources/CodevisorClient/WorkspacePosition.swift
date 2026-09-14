import Foundation

/// ASCII hex positions, compared identically by Swift, JavaScript and SQLite.
/// The creation prefix reserves space above manual moves for new workspaces.
public enum WorkspacePosition {
  private static let epochMax: Int64 = 0xffffffffffff
  private static let digits = Array("0123456789abcdef".utf8)

  public static func isValid(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return (13...1024).contains(bytes.count) && bytes.last != 48
      && bytes.allSatisfy { digits.contains($0) }
  }

  public static func epoch(_ position: String) -> Int64 {
    epochMax - (Int64(position.prefix(12), radix: 16) ?? epochMax)
  }

  public static func initial(createdAt: Date, id: UUID, after head: String? = nil) -> String {
    let millis = Int64((createdAt.timeIntervalSince1970 * 1000).rounded(.down))
    let generation = min(epochMax - 1, max(0, millis, head.map { epoch($0) + 1 } ?? 0))
    return String(format: "%012llx", epochMax - generation)
      + "8" + id.uuidString.lowercased().replacingOccurrences(of: "-", with: "") + "8"
  }

  /// The suffix makes concurrent moves into the same gap independently
  /// addressable. Future moves can insert between their complete keys.
  public static func between(_ lower: String?, _ upper: String?, id: UUID) -> String? {
    guard lower.map(isValid) ?? true, upper.map(isValid) ?? true,
      lower == nil || upper == nil || lower! < upper!
    else { return nil }
    // Prepending stays within the newest observed creation generation.
    let a = Array((lower ?? String(upper?.prefix(12) ?? "ffffffffffff")).utf8)
    var b = upper.map { Array($0.utf8) }
    var result: [UInt8] = []
    var index = 0
    while result.count < 980 {
      let low = index < a.count ? Int(digits.firstIndex(of: a[index])!) : 0
      let high = b.flatMap { index < $0.count ? Int(digits.firstIndex(of: $0[index])!) : nil } ?? 16
      if high - low > 1 {
        result.append(digits[(low + high) / 2])
        return String(decoding: result, as: UTF8.self) + "8"
          + id.uuidString.lowercased().replacingOccurrences(of: "-", with: "") + "8"
      }
      result.append(digits[low])
      if low < high { b = nil }
      index += 1
    }
    return nil
  }
}

/// Shares the observed creation frontier across a client's machine transports.
/// It carries only a position hint; servers assign identities exactly once.
public final class WorkspaceOrderClock: @unchecked Sendable {
  public static let shared = WorkspaceOrderClock()
  private let lock = NSLock()
  private var value: String?
  public init() {}
  public var head: String? { lock.withLock { value } }
  public func observe(_ position: String?) {
    guard let position, WorkspacePosition.isValid(position) else { return }
    lock.withLock {
      if value == nil || position < value! { value = position }
    }
  }
}
