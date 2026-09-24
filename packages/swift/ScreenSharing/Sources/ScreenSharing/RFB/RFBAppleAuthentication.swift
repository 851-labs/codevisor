import CommonCrypto
import CryptoKit
import Foundation

/// Apple's account sign-in for Screen Sharing, RFB security type 30
/// ("Diffie-Hellman", 851-2341), as noVNC and libvncclient implement it:
///
/// 1. The server sends a generator (u16), a key length (u16), the prime and
///    its public key (key length bytes each, big-endian).
/// 2. The client picks a private key, computes its public key and the shared
///    secret, and derives an AES-128 key: MD5 of the shared secret.
/// 3. It sends 128 bytes of credentials (username, then password, each
///    NUL-terminated in a 64-byte block padded with random bytes) encrypted
///    with AES-128-ECB, followed by its public key.
///
/// Signing in with a macOS account (not the Screen Sharing VNC password) is
/// what lets the Mac know who is connecting.
public enum RFBAppleAuthentication {
  /// Key lengths accepted from a server (a 128-bit to 8192-bit group).
  static let keyLengths = 16...1024

  /// The client's reply: encrypted credentials, then its public key.
  static func response(
    generator: UInt16, prime: [UInt8], serverKey: [UInt8], username: String, password: String,
    privateKey: [UInt8]? = nil, padding: () -> UInt8 = { UInt8.random(in: 0...255) }
  ) throws -> [UInt8] {
    let length = prime.count
    guard keyLengths.contains(length), serverKey.count == length else {
      throw RFBError.malformed("Diffie-Hellman key of \(length) bytes")
    }
    let modulus = RFBBigUInt(bytes: prime)
    let theirs = RFBBigUInt(bytes: serverKey)
    guard modulus.isOdd, theirs < modulus, generator > 1 else {
      throw RFBError.malformed("Diffie-Hellman parameters")
    }
    let secret = RFBBigUInt(bytes: privateKey ?? (0..<length).map { _ in UInt8.random(in: 0...255) })
    let ours = RFBBigUInt(UInt32(generator)).power(secret, modulo: modulus)
    let shared = theirs.power(secret, modulo: modulus)
    let key = Array(Insecure.MD5.hash(data: shared.bytes(count: length)))
    let credentials = try block(username, padding: padding) + block(password, padding: padding)
    return try aes128ECB(encrypt: true, key: key, data: credentials) + ours.bytes(count: length)
  }

  /// A 64-byte credential block: UTF-8, NUL-terminated, then random padding.
  static func block(_ text: String, padding: () -> UInt8) throws -> [UInt8] {
    let bytes = Array(text.utf8)
    guard bytes.count < 64 else { throw RFBError.authenticationFailed("The username or password is too long.") }
    return bytes + [0] + (0..<(63 - bytes.count)).map { _ in padding() }
  }

  /// The text of a credential block, up to its NUL (the reference server's side).
  public static func text(ofBlock block: ArraySlice<UInt8>) -> String {
    String(decoding: block.prefix { $0 != 0 }, as: UTF8.self)
  }

  /// AES-128 in ECB mode, whole blocks, no padding.
  public static func aes128ECB(encrypt: Bool, key: [UInt8], data: [UInt8]) throws -> [UInt8] {
    guard key.count == kCCKeySizeAES128, data.count.isMultiple(of: kCCBlockSizeAES128) else {
      throw RFBError.malformed("AES-128-ECB input")
    }
    var output = [UInt8](repeating: 0, count: data.count)
    var moved = 0
    let status = CCCrypt(
      CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
      key, key.count, nil, data, data.count, &output, output.count, &moved)
    guard status == kCCSuccess, moved == data.count else { throw RFBError.malformed("AES-128-ECB failed") }
    return output
  }
}

/// Just enough unsigned big-integer arithmetic for Diffie-Hellman: modular
/// exponentiation with Montgomery multiplication (no division), for an odd
/// modulus. Little-endian 32-bit limbs.
public struct RFBBigUInt: Equatable, Comparable, Sendable {
  var limbs: [UInt32]

  public init(_ value: UInt32) { limbs = [value] }

  /// Big-endian bytes.
  public init(bytes: [UInt8]) {
    var limbs = [UInt32](repeating: 0, count: max(1, (bytes.count + 3) / 4))
    for (index, byte) in bytes.reversed().enumerated() { limbs[index / 4] |= UInt32(byte) << (8 * (index % 4)) }
    self.limbs = limbs
    trim()
  }

  /// Big-endian bytes, left-padded to `count` (the value must fit).
  public func bytes(count: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    for index in 0..<min(count, limbs.count * 4) {
      out[count - 1 - index] = UInt8(truncatingIfNeeded: limbs[index / 4] >> (8 * (index % 4)))
    }
    return out
  }

  var isOdd: Bool { limbs[0] & 1 == 1 }
  private var bitWidth: Int {
    guard let top = limbs.last, top != 0 else { return 0 }
    return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
  }

  private mutating func trim() {
    while limbs.count > 1, limbs.last == 0 { limbs.removeLast() }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
    for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
      return lhs.limbs[index] < rhs.limbs[index]
    }
    return false
  }

  /// `self ^ exponent mod modulus`, for an odd modulus and `self < modulus`.
  public func power(_ exponent: Self, modulo modulus: Self) -> Self {
    let context = Montgomery(modulus: modulus.limbs)
    var result = context.toMontgomery([1])
    let base = context.toMontgomery(limbs)
    for bit in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
      result = context.multiply(result, result)
      if exponent.limbs[bit / 32] >> (bit % 32) & 1 == 1 { result = context.multiply(result, base) }
    }
    var value = Self(0)
    value.limbs = context.multiply(result, [1] + [UInt32](repeating: 0, count: modulus.limbs.count - 1))
    value.trim()
    return value
  }

  /// Montgomery arithmetic modulo `m` with R = 2^(32n) (CIOS multiplication).
  struct Montgomery {
    let m: [UInt32]
    let n: Int
    /// -m⁻¹ mod 2³².
    let inverse: UInt32
    /// R² mod m.
    let r2: [UInt32]

    init(modulus: [UInt32]) {
      m = modulus
      n = modulus.count
      var x: UInt32 = 1  // Newton's iteration: m₀·x ≡ 1 (mod 2³²) after five rounds.
      for _ in 0..<5 { x = x &* (2 &- modulus[0] &* x) }
      inverse = 0 &- x
      // R² mod m by doubling 1, 2·32·n times, subtracting m whenever it's reached.
      var value = [UInt32](repeating: 0, count: n + 1)
      value[0] = 1
      for _ in 0..<(64 * n) {
        var carry: UInt32 = 0
        for index in 0...n {
          let next = value[index] >> 31
          value[index] = value[index] << 1 | carry
          carry = next
        }
        if !Self.less(value, modulus) { Self.subtract(&value, modulus) }
      }
      r2 = Array(value.prefix(n))
    }

    func toMontgomery(_ value: [UInt32]) -> [UInt32] {
      multiply(value + [UInt32](repeating: 0, count: max(0, n - value.count)), r2)
    }

    /// a·b·R⁻¹ mod m, for a, b < m.
    func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
      var t = [UInt32](repeating: 0, count: n + 2)
      for i in 0..<n {
        var carry: UInt64 = 0
        let bi = UInt64(b[i])
        for j in 0..<n {
          let sum = UInt64(t[j]) + UInt64(a[j]) * bi + carry
          t[j] = UInt32(truncatingIfNeeded: sum)
          carry = sum >> 32
        }
        var sum = UInt64(t[n]) + carry
        t[n] = UInt32(truncatingIfNeeded: sum)
        t[n + 1] = UInt32(sum >> 32)
        let factor = UInt64(t[0] &* inverse)
        sum = UInt64(t[0]) + factor * UInt64(m[0])
        carry = sum >> 32
        for j in 1..<n {
          sum = UInt64(t[j]) + factor * UInt64(m[j]) + carry
          t[j - 1] = UInt32(truncatingIfNeeded: sum)
          carry = sum >> 32
        }
        sum = UInt64(t[n]) + carry
        t[n - 1] = UInt32(truncatingIfNeeded: sum)
        t[n] = t[n + 1] + UInt32(sum >> 32)
      }
      var result = Array(t.prefix(n + 1))
      if !Self.less(result, m) { Self.subtract(&result, m) }
      return Array(result.prefix(n))
    }

    /// a < b, where a may carry one more limb than b.
    static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
      for index in stride(from: a.count - 1, through: 0, by: -1) {
        let bi = index < b.count ? b[index] : 0
        if a[index] != bi { return a[index] < bi }
      }
      return false
    }

    /// a -= b, for a ≥ b.
    static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
      var borrow: Int64 = 0
      for index in 0..<a.count {
        let difference = Int64(a[index]) - Int64(index < b.count ? b[index] : 0) - borrow
        a[index] = UInt32(truncatingIfNeeded: difference)
        borrow = difference < 0 ? 1 : 0
      }
    }
  }
}
