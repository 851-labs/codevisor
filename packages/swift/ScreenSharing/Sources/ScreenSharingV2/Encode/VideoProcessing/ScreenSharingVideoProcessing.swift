import CoreMedia
import VideoToolbox

struct ScreenSharingVideoProcessing: @unchecked Sendable {
  typealias Create =
    @convention(c) (
      CFAllocator?, Int32, Int32, CMVideoCodecType, CFDictionary?, CFDictionary?, CFAllocator?,
      VTCompressionOutputCallback?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Unmanaged<AnyObject>?>
    ) -> OSStatus
  typealias SetProperty = @convention(c) (AnyObject, CFString, CFTypeRef?) -> OSStatus
  typealias Encode =
    @convention(c) (
      AnyObject, CVImageBuffer, CMTime, CMTime, CFDictionary?, UnsafeMutableRawPointer?,
      UnsafeMutablePointer<VTEncodeInfoFlags>?
    ) -> OSStatus
  typealias Complete = @convention(c) (AnyObject, CMTime) -> OSStatus
  typealias Invalidate = @convention(c) (AnyObject) -> Void

  static let loaded = Result { try ScreenSharingVideoProcessing() }

  let create: Create
  let setProperty: SetProperty
  let encode: Encode
  let complete: Complete
  let invalidate: Invalidate
  let keys: ScreenSharingVCPKeys

  private init() throws {
    create = try ScreenSharingPrivateSymbols.function("VCPCompressionSessionCreate", Create.self)
    setProperty = try ScreenSharingPrivateSymbols.function("VCPCompressionSessionSetProperty", SetProperty.self)
    encode = try ScreenSharingPrivateSymbols.function("VCPCompressionSessionEncodeFrame", Encode.self)
    complete = try ScreenSharingPrivateSymbols.function("VCPCompressionSessionCompleteFrames", Complete.self)
    invalidate = try ScreenSharingPrivateSymbols.function("VCPCompressionSessionInvalidate", Invalidate.self)
    keys = try ScreenSharingVCPKeys()
  }

  static func load() throws -> ScreenSharingVideoProcessing {
    try loaded.get()
  }
}
