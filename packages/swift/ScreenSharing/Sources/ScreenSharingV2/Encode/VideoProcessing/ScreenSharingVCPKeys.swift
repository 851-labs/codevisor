import CoreFoundation

struct ScreenSharingVCPKeys: @unchecked Sendable {
  static let usage = 42
  static var realTime: CFString { "RealTime" as CFString }
  static var main444: CFString { "HEVC_Main444_AutoLevel" as CFString }

  let usage: CFString
  let acknowledgedTokens: CFString
  let requireToken: CFString
  let packetErrorRate: CFString?
  let roundTripDelay: CFString?
  let transmissionBitRate: CFString?

  init() throws {
    usage = try ScreenSharingPrivateSymbols.string("kVTVideoEncoderSpecification_Usage")
    acknowledgedTokens = try ScreenSharingPrivateSymbols.string("kVTEncodeFrameOptionKey_AcknowledgedTokens")
    requireToken = try ScreenSharingPrivateSymbols.string("kVTSampleAttachmentKey_RequireAcknowledgementToken")
    packetErrorRate = try? ScreenSharingPrivateSymbols.string("kVTEncodeFrameOptionKey_PacketErrorRate")
    roundTripDelay = try? ScreenSharingPrivateSymbols.string("kVTEncodeFrameOptionKey_RoundTripDelay")
    transmissionBitRate = try? ScreenSharingPrivateSymbols.string("kVTEncodeFrameOptionKey_AverageTransmissionBitRate")
  }
}
