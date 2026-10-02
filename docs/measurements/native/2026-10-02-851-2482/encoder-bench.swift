import VideoToolbox
import CoreVideo
import Foundation
// venc W H FORMAT(bgra|444|nv12) PROFILE(main444|main) PENDING SPEED(0|1) — 60 fps paced encode of noisy frames.
let a = CommandLine.arguments
let (w, h) = (Int(a[1])!, Int(a[2])!), format = a[3], profile = a[4], maxPending = Int(a[5])!, speed = a[6] == "1"
final class Stats: @unchecked Sendable { let lock = NSLock(); var start: [Int: UInt64] = [:]; var lat: [Double] = []; var done = 0; var bytes = 0 }
let stats = Stats()
var s: VTCompressionSession?
let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { ref, frame, _, _, sample in
  let st = Unmanaged<Stats>.fromOpaque(ref!).takeUnretainedValue(); let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  st.lock.withLock { if let t0 = st.start.removeValue(forKey: Int(bitPattern: frame)) { st.lat.append(Double(now - t0) / 1e6) }; st.done += 1
    if let sample, let b = CMSampleBufferGetDataBuffer(sample) { st.bytes += CMBlockBufferGetDataLength(b) } }
}, refcon: Unmanaged.passUnretained(stats).toOpaque(), compressionSessionOut: &s)
let session = s!
func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(session, key: k, value: v) }
set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue); set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
if speed { set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue) }
set(kVTCompressionPropertyKey_ProfileLevel, (profile == "main444" ? "HEVC_Main444_AutoLevel" : "HEVC_Main_AutoLevel") as CFString)
set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber); set(kVTCompressionPropertyKey_AverageBitRate, 45_000_000 as CFNumber)
set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 3600 as CFNumber)
VTCompressionSessionPrepareToEncodeFrames(session)
let pf: OSType = format == "bgra" ? kCVPixelFormatType_32BGRA : format == "444" ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
// 8 pre-filled noisy frames, cycled: content like the frame clock's video mode, without per-frame CPU cost.
var frames: [CVPixelBuffer] = []
var seed: UInt64 = 1
for _ in 0..<8 {
  var pb: CVPixelBuffer?; CVPixelBufferCreate(nil, w, h, pf, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
  CVPixelBufferLockBaseAddress(pb!, [])
  let planes = max(1, CVPixelBufferGetPlaneCount(pb!))
  for p in 0..<planes {
    let base = (CVPixelBufferGetPlaneCount(pb!) == 0 ? CVPixelBufferGetBaseAddress(pb!) : CVPixelBufferGetBaseAddressOfPlane(pb!, p))!.assumingMemoryBound(to: UInt64.self)
    let bytes = CVPixelBufferGetPlaneCount(pb!) == 0 ? CVPixelBufferGetDataSize(pb!) : CVPixelBufferGetBytesPerRowOfPlane(pb!, p) * CVPixelBufferGetHeightOfPlane(pb!, p)
    for i in 0..<(bytes / 8) { seed = seed &* 6364136223846793005 &+ 1442695040888963407; base[i] = (i % 97 < 60) ? seed : 0x8080808080808080 }
  }
  CVPixelBufferUnlockBaseAddress(pb!, []); frames.append(pb!)
}
let seconds = 6, total = 60 * seconds
var dropped = 0
let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
for i in 0..<total {
  let due = t0 + UInt64(i) * 16_666_667
  while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < due { usleep(200) }
  let pending = stats.lock.withLock { stats.start.count }
  if pending >= maxPending { dropped += 1; continue }
  stats.lock.withLock { stats.start[i + 1] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
  VTCompressionSessionEncodeFrame(session, imageBuffer: frames[i % 8], presentationTimeStamp: CMTime(value: Int64(i), timescale: 60), duration: .invalid, frameProperties: nil, sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: i + 1), infoFlagsOut: nil)
}
VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
let lat = stats.lat.sorted()
func q(_ p: Double) -> Double { lat.isEmpty ? 0 : lat[min(lat.count - 1, Int(Double(lat.count) * p))] }
let fps = Double(stats.done) / Double(seconds), dropPct = Double(dropped) * 100 / Double(total), mbit = Double(stats.bytes) * 8 / 1e6 / Double(seconds)
print("\(w)x\(h) \(format) \(profile) pending \(maxPending) speed \(speed ? 1 : 0): encoded \(String(format: "%.1f", fps)) fps, dropped \(String(format: "%.0f", dropPct))%, latency p50 \(String(format: "%.1f", q(0.5))) p95 \(String(format: "%.1f", q(0.95))) ms, \(String(format: "%.0f", mbit)) Mbit/s")
