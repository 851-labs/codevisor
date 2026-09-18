import CommonCrypto
import Foundation

/// VNC Authentication (security type 2): the 16-byte challenge encrypted with
/// DES in ECB mode, keyed by the first eight bytes of the password with each
/// byte's bits reversed — VNC's historical quirk, which every server expects.
public enum RFBVNCAuthentication {
  public static func response(challenge: [UInt8], password: String) -> [UInt8] {
    precondition(challenge.count == 16)
    var key = Array(RFBLatin1.encode(password).prefix(8))
    key.append(contentsOf: repeatElement(0, count: 8 - key.count))
    key = key.map { byte in
      var reversed: UInt8 = 0
      for bit in 0..<8 where byte & (1 << UInt8(bit)) != 0 { reversed |= 1 << UInt8(7 - bit) }
      return reversed
    }
    var output = [UInt8](repeating: 0, count: 16)
    var moved = 0
    let status = CCCrypt(
      CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode), key, kCCKeySizeDES, nil,
      challenge, challenge.count, &output, output.count, &moved)
    precondition(status == kCCSuccess && moved == 16, "DES failed (\(status))")
    return output
  }
}
