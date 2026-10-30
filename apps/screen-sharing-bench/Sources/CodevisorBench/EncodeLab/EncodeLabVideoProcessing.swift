import CoreMedia
import VideoToolbox

struct EncodeLabVideoProcessing {
  typealias Create = @convention(c) (
    CFAllocator?, Int32, Int32, CMVideoCodecType, CFDictionary?, CFDictionary?, CFAllocator?,
    VTCompressionOutputCallback?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Unmanaged<AnyObject>?>
  ) -> OSStatus
  typealias SetProperty = @convention(c) (AnyObject, CFString, CFTypeRef?) -> OSStatus
  typealias CopyProperty = @convention(c) (
    AnyObject, CFString, CFAllocator?, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>
  ) -> OSStatus
  typealias Encode = @convention(c) (
    AnyObject, CVImageBuffer, CMTime, CMTime, CFDictionary?, UnsafeMutableRawPointer?,
    UnsafeMutablePointer<VTEncodeInfoFlags>?
  ) -> OSStatus
  typealias Complete = @convention(c) (AnyObject, CMTime) -> OSStatus
  typealias Invalidate = @convention(c) (AnyObject) -> Void

  static let usage = 42

  let create: Create
  let setProperty: SetProperty
  let copyProperty: CopyProperty
  let encode: Encode
  let complete: Complete
  let invalidate: Invalidate
  let usageKey: CFString
  let acknowledgedTokensKey: CFString
  let requireTokenKey: CFString

  init() throws {
    create = try EncodeLabPrivateSymbols.function("VCPCompressionSessionCreate", Create.self)
    setProperty = try EncodeLabPrivateSymbols.function("VCPCompressionSessionSetProperty", SetProperty.self)
    copyProperty = try EncodeLabPrivateSymbols.function("VCPCompressionSessionCopyProperty", CopyProperty.self)
    encode = try EncodeLabPrivateSymbols.function("VCPCompressionSessionEncodeFrame", Encode.self)
    complete = try EncodeLabPrivateSymbols.function("VCPCompressionSessionCompleteFrames", Complete.self)
    invalidate = try EncodeLabPrivateSymbols.function("VCPCompressionSessionInvalidate", Invalidate.self)
    usageKey = try EncodeLabPrivateSymbols.string("kVTVideoEncoderSpecification_Usage")
    acknowledgedTokensKey = try EncodeLabPrivateSymbols.string("kVTEncodeFrameOptionKey_AcknowledgedTokens")
    requireTokenKey = try EncodeLabPrivateSymbols.string("kVTSampleAttachmentKey_RequireAcknowledgementToken")
  }
}
