import CoreFoundation
import Darwin

enum TCCPreflight {
  private typealias Function = @convention(c) (CFString, CFDictionary?) -> Int32

  private static let granted: Int32 = 0

  static func isAllowed(_ service: String) -> Bool {
    guard let preflight = resolve() else { return false }
    return preflight(service as CFString, nil) == granted
  }

  private static func resolve() -> Function? {
    let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY)
    guard let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
    return unsafeBitCast(symbol, to: Function.self)
  }
}
