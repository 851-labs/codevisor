import CommonCrypto
import CryptoKit
import Foundation

public enum RFBAppleAuthentication {
  static let keyLengths = 16...1024

  static func privateKeyLength(forKeyLength length: Int) -> Int { min(length, 64) }

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
    let random = (0..<privateKeyLength(forKeyLength: length)).map { _ in UInt8.random(in: 0...255) }
    let secret = RFBBigUInt(bytes: privateKey ?? random)
    let ours = RFBBigUInt(UInt64(generator)).power(secret, modulo: modulus)
    let shared = theirs.power(secret, modulo: modulus)
    let key = Array(Insecure.MD5.hash(data: shared.bytes(count: length)))
    let credentials = try block(username, padding: padding) + block(password, padding: padding)
    return try aes128ECB(encrypt: true, key: key, data: credentials) + ours.bytes(count: length)
  }

  static func block(_ text: String, padding: () -> UInt8) throws -> [UInt8] {
    let bytes = Array(text.utf8)
    guard bytes.count < 64 else { throw RFBError.authenticationFailed("The username or password is too long.") }
    return bytes + [0] + (0..<(63 - bytes.count)).map { _ in padding() }
  }

  public static func text(ofBlock block: ArraySlice<UInt8>) -> String {
    String(decoding: block.prefix { $0 != 0 }, as: UTF8.self)
  }

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

public struct RFBBigUInt: Equatable, Comparable, Sendable {
  var limbs: [UInt64]

  public init(_ value: UInt64) { limbs = [value] }

  public init(bytes: [UInt8]) {
    var limbs = [UInt64](repeating: 0, count: max(1, (bytes.count + 7) / 8))
    for (index, byte) in bytes.reversed().enumerated() { limbs[index / 8] |= UInt64(byte) << (8 * (index % 8)) }
    self.limbs = limbs
    trim()
  }

  public func bytes(count: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    for index in 0..<min(count, limbs.count * 8) {
      out[count - 1 - index] = UInt8(truncatingIfNeeded: limbs[index / 8] >> (8 * (index % 8)))
    }
    return out
  }

  var isOdd: Bool { limbs[0] & 1 == 1 }
  private var bitWidth: Int {
    guard let top = limbs.last, top != 0 else { return 0 }
    return (limbs.count - 1) * 64 + (64 - top.leadingZeroBitCount)
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

  public func power(_ exponent: Self, modulo modulus: Self) -> Self {
    let context = Montgomery(modulus: modulus.limbs)
    var result = context.toMontgomery([1])
    let base = context.toMontgomery(limbs)
    var scratch = [UInt64](repeating: 0, count: context.n + 2)
    result.withUnsafeMutableBufferPointer { result in
      base.withUnsafeBufferPointer { base in
        scratch.withUnsafeMutableBufferPointer { scratch in
          context.m.withUnsafeBufferPointer { modulus in
            let r = result.baseAddress!, b = base.baseAddress!, t = scratch.baseAddress!, m = modulus.baseAddress!
            for bit in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
              context.multiply(r, r, into: r, modulus: m, scratch: t)
              if exponent.limbs[bit / 64] >> (bit % 64) & 1 == 1 {
                context.multiply(r, b, into: r, modulus: m, scratch: t)
              }
            }
          }
        }
      }
    }
    var value = Self(0)
    value.limbs = context.multiply(result, [1] + [UInt64](repeating: 0, count: modulus.limbs.count - 1))
    value.trim()
    return value
  }

  struct Montgomery {
    let m: [UInt64]
    let n: Int
    let inverse: UInt64
    let r2: [UInt64]

    init(modulus: [UInt64]) {
      m = modulus
      n = modulus.count
      var x: UInt64 = 1
      for _ in 0..<6 { x = x &* (2 &- modulus[0] &* x) }
      inverse = 0 &- x
      var value = [UInt64](repeating: 0, count: n + 1)
      value[0] = 1
      for _ in 0..<(128 * n) {
        var carry: UInt64 = 0
        for index in 0...n {
          let next = value[index] >> 63
          value[index] = value[index] << 1 | carry
          carry = next
        }
        if !Self.less(value, modulus) { Self.subtract(&value, modulus) }
      }
      r2 = Array(value.prefix(n))
    }

    func toMontgomery(_ value: [UInt64]) -> [UInt64] {
      multiply(value + [UInt64](repeating: 0, count: max(0, n - value.count)), r2)
    }

    func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
      var result = [UInt64](repeating: 0, count: n)
      var scratch = [UInt64](repeating: 0, count: n + 2)
      a.withUnsafeBufferPointer { a in
        b.withUnsafeBufferPointer { b in
          result.withUnsafeMutableBufferPointer { out in
            scratch.withUnsafeMutableBufferPointer { t in
              m.withUnsafeBufferPointer { m in
                multiply(
                  a.baseAddress!, b.baseAddress!, into: out.baseAddress!, modulus: m.baseAddress!,
                  scratch: t.baseAddress!)
              }
            }
          }
        }
      }
      return result
    }

    func multiply(
      _ a: UnsafePointer<UInt64>, _ b: UnsafePointer<UInt64>, into out: UnsafeMutablePointer<UInt64>,
      modulus m: UnsafePointer<UInt64>, scratch t: UnsafeMutablePointer<UInt64>
    ) {
      let n = n, inverse = inverse
      t.update(repeating: 0, count: n + 2)
      for i in 0..<n {
        var carry: UInt64 = 0
        let bi = b[i]
        for j in 0..<n {
          let (high, low) = a[j].multipliedFullWidth(by: bi)
          let (sum, overflow1) = low.addingReportingOverflow(t[j])
          let (total, overflow2) = sum.addingReportingOverflow(carry)
          t[j] = total
          carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
        }
        let (top, overflow) = t[n].addingReportingOverflow(carry)
        t[n] = top
        t[n + 1] = overflow ? 1 : 0
        let factor = t[0] &* inverse
        var (high, low) = factor.multipliedFullWidth(by: m[0])
        carry = high &+ (low.addingReportingOverflow(t[0]).overflow ? 1 : 0)
        for j in 1..<n {
          (high, low) = factor.multipliedFullWidth(by: m[j])
          let (sum, overflow1) = low.addingReportingOverflow(t[j])
          let (total, overflow2) = sum.addingReportingOverflow(carry)
          t[j - 1] = total
          carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
        }
        let (last, overflow3) = t[n].addingReportingOverflow(carry)
        t[n - 1] = last
        t[n] = t[n + 1] &+ (overflow3 ? 1 : 0)
      }
      var atLeast = t[n] != 0
      if !atLeast {
        atLeast = true
        for index in stride(from: n - 1, through: 0, by: -1) where t[index] != m[index] {
          atLeast = t[index] > m[index]
          break
        }
      }
      var borrow = false
      for index in 0..<n {
        guard atLeast else {
          out[index] = t[index]
          continue
        }
        let (difference, borrow1) = t[index].subtractingReportingOverflow(m[index])
        let (final, borrow2) = difference.subtractingReportingOverflow(borrow ? 1 : 0)
        out[index] = final
        borrow = borrow1 || borrow2
      }
    }

    static func less(_ a: [UInt64], _ b: [UInt64]) -> Bool {
      for index in stride(from: a.count - 1, through: 0, by: -1) {
        let bi = index < b.count ? b[index] : 0
        if a[index] != bi { return a[index] < bi }
      }
      return false
    }

    static func subtract(_ a: inout [UInt64], _ b: [UInt64]) {
      var borrow = false
      for index in 0..<a.count {
        let (difference, borrow1) = a[index].subtractingReportingOverflow(index < b.count ? b[index] : 0)
        let (final, borrow2) = difference.subtractingReportingOverflow(borrow ? 1 : 0)
        a[index] = final
        borrow = borrow1 || borrow2
      }
    }
  }
}
