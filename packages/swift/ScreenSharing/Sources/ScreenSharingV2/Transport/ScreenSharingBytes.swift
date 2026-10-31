public protocol ScreenSharingBytes: Sendable {
  var count: Int { get }
  func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result
}
