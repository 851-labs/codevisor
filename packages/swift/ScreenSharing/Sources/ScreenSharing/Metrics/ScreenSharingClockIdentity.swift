import Darwin

package enum ScreenSharingClockIdentity {
  package static let current = hash(bootSession())

  package static func hash(_ text: String) -> UInt64 {
    guard !text.isEmpty else { return 0 }

    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    return value
  }

  private static func bootSession() -> String {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }

    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
