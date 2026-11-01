import CodevisorNet

struct ScreenSharingMediaBytes: ScreenSharingBytes, @unchecked Sendable {
  private let bytes: MediaBytes

  init(_ bytes: MediaBytes) {
    self.bytes = bytes
  }

  var count: Int { bytes.withUnsafeBytes(\.count) }

  func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
    try bytes.withUnsafeBytes(body)
  }
}
