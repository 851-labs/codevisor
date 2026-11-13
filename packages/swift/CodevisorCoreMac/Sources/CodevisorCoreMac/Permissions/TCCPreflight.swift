import CoreFoundation
import Darwin

enum TCCPreflight {
  private typealias Function = @convention(c) (CFString, CFDictionary?) -> Int32

  enum Status {
    case allowed
    case denied
    case undetermined
  }

  private static let granted: Int32 = 0
  private static let refused: Int32 = 1

  static func isAllowed(_ service: String) -> Bool {
    status(of: service) == .allowed
  }

  static func status(of service: String) -> Status {
    guard let preflight = resolve() else { return .undetermined }
    switch preflight(service as CFString, nil) {
    case granted: return .allowed
    case refused: return .denied
    default: return .undetermined
    }
  }

  private static func resolve() -> Function? {
    let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY)
    guard let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
    return unsafeBitCast(symbol, to: Function.self)
  }
}
