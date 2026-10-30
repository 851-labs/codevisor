import CoreFoundation
import Darwin

enum EncodeLabPrivateSymbols {
  static let videoToolbox = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox"
  static let videoProcessing = "/System/Library/PrivateFrameworks/VideoProcessing.framework/VideoProcessing"

  static func string(_ name: String) throws -> CFString {
    let symbol = try address(name, in: videoToolbox)
    return symbol.assumingMemoryBound(to: CFString.self).pointee
  }

  static func function<Function>(_ name: String, _ type: Function.Type) throws -> Function {
    unsafeBitCast(try address(name, in: videoProcessing), to: type)
  }

  private static func address(_ name: String, in library: String) throws -> UnsafeMutableRawPointer {
    guard let handle = dlopen(library, RTLD_NOW), let symbol = dlsym(handle, name) else {
      throw EncodeLabError.missingSymbol(name)
    }

    return symbol
  }
}
