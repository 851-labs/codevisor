import CoreMedia
import ScreenSharing
import VideoToolbox

final class ScreenSharingVCPSession: @unchecked Sendable {
  let sink: ScreenSharingVCPOutputSink
  let api: ScreenSharingVideoProcessing
  private let session: AnyObject
  private let refcon: Unmanaged<ScreenSharingVCPOutputSink>
  private let frameDuration: CMTime

  init(
    api: ScreenSharingVideoProcessing, session: AnyObject, sink: ScreenSharingVCPOutputSink,
    refcon: Unmanaged<ScreenSharingVCPOutputSink>, framesPerSecond: Int
  ) {
    self.api = api
    self.session = session
    self.sink = sink
    self.refcon = refcon
    frameDuration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
  }

  func encode(
    _ pixelBuffer: CVPixelBuffer, submission: UInt64, presentationNs: Int64, options: CFDictionary?
  )
    -> OSStatus
  {
    api.encode(
      session, pixelBuffer, CMTime(value: presentationNs, timescale: 1_000_000_000), frameDuration, options,
      UnsafeMutableRawPointer(bitPattern: UInt(submission)), nil)
  }

  func set(_ key: CFString, _ value: CFTypeRef) throws {
    let status = api.setProperty(session, key, value)
    guard status == noErr else { throw ScreenSharingError.codec("Set VCP \(key)", status) }
  }

  func setBitrate(_ bitsPerSecond: Int, windowBitsPerSecond: Int) throws {
    try set(kVTCompressionPropertyKey_AverageBitRate, bitsPerSecond as CFNumber)
    try set(kVTCompressionPropertyKey_DataRateLimits, ScreenSharingVCPRate.limits(bitsPerSecond: windowBitsPerSecond))
  }

  func close() {
    _ = api.complete(session, .invalid)
    api.invalidate(session)
    sink.onOutput(nil)
    refcon.release()
  }
}
