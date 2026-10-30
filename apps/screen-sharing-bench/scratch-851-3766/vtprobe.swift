// 851-3766 scratch probe (never merged): does VideoToolbox honour the private keys AVConference and
// VideoProcessing use, and what do they do to encode latency and size? Prints one JSON line per run.
// swiftc -O vtprobe.swift -o vtprobe && ./vtprobe [seconds-per-run] [filter]
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

func key(_ name: String) -> CFString? {
  guard let handle = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW),
    let symbol = dlsym(handle, name)
  else { return nil }
  return symbol.assumingMemoryBound(to: CFString.self).pointee
}

typealias VCPCreate = @convention(c) (
  CFAllocator?, Int32, Int32, CMVideoCodecType, CFDictionary?, CFDictionary?, CFAllocator?,
  VTCompressionOutputCallback?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Unmanaged<AnyObject>?>
) -> OSStatus
typealias VCPSetProperty = @convention(c) (AnyObject, CFString, CFTypeRef?) -> OSStatus
typealias VCPCopyProperty = @convention(c) (AnyObject, CFString, CFAllocator?, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> OSStatus
typealias VCPEncode = @convention(c) (
  AnyObject, CVImageBuffer, CMTime, CMTime, CFDictionary?, UnsafeMutableRawPointer?,
  UnsafeMutablePointer<VTEncodeInfoFlags>?
) -> OSStatus
typealias VCPComplete = @convention(c) (AnyObject, CMTime) -> OSStatus
typealias VCPInvalidate = @convention(c) (AnyObject) -> Void
typealias VCPGetPool = @convention(c) (AnyObject) -> Unmanaged<CVPixelBufferPool>?
let vcp = dlopen("/System/Library/PrivateFrameworks/VideoProcessing.framework/VideoProcessing", RTLD_NOW)
func vcpSymbol<T>(_ name: String, _ type: T.Type) -> T? {
  guard let vcp, let symbol = dlsym(vcp, name) else { return nil }
  return unsafeBitCast(symbol, to: type)
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func nowMs() -> Double { Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

func percentile(_ values: [Double], _ p: Double) -> Double {
  guard !values.isEmpty else { return .nan }
  let sorted = values.sorted()
  return sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
}

enum Scene: String, CaseIterable { case scroll, idle, video }

struct Config {
  let name: String
  var spec: [String: Any] = [:]
  var properties: [String: Any] = [:]
  var sections = 0
  var sectionOffsets: ((Int, Int, Int) -> [Int])? = nil
  var vcpTiles = 0
  var inputFormat: OSType = 0
}

final class Content {
  let width: Int, height: Int
  let document: [UInt8]
  let documentRows: Int
  var noise: [[UInt8]] = []

  init(width: Int, height: Int) {
    self.width = width
    self.height = height
    documentRows = height * 3
    var rng = SystemRandomNumberGenerator()
    var doc = [UInt8](repeating: 255, count: width * documentRows * 4)
    let lineHeight = 36, glyphWidth = 16, glyphHeight = 22
    for line in stride(from: 8, to: documentRows - lineHeight, by: lineHeight) {
      var x = 40
      let lineEnd = Int.random(in: width / 3...width - 40, using: &rng)
      while x < lineEnd {
        if Int.random(in: 0..<6, using: &rng) == 0 { x += glyphWidth; continue }
        let shade = UInt8.random(in: 0...90, using: &rng)
        let tint = Int.random(in: 0..<8, using: &rng) == 0
        for y in line + 6..<line + 6 + glyphHeight where Int.random(in: 0..<4, using: &rng) != 0 {
          for gx in x + 2..<x + glyphWidth - 2 {
            let o = (y * width + gx) * 4
            doc[o] = tint ? 200 : shade
            doc[o + 1] = shade
            doc[o + 2] = tint ? 40 : shade
          }
        }
        x += glyphWidth
      }
    }
    document = doc
    for _ in 0..<8 {
      noise.append((0..<(width * height * 4)).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }
  }

  func fill(_ buffer: CVPixelBuffer, scene: Scene, frame: Int) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let rowBytes = width * 4
    switch scene {
    case .scroll:
      let offset = (frame * 20) % (documentRows - height)
      document.withUnsafeBufferPointer { doc in
        for y in 0..<height { memcpy(base + y * stride, doc.baseAddress! + (offset + y) * rowBytes, rowBytes) }
      }
    case .idle:
      document.withUnsafeBufferPointer { doc in
        for y in 0..<height { memcpy(base + y * stride, doc.baseAddress! + y * rowBytes, rowBytes) }
      }
      let on = (frame / 15) % 2 == 0
      for y in 300..<336 { memset(base + y * stride + 600 * 4, on ? 0 : 255, 4 * 4) }
    case .video:
      noise[frame % noise.count].withUnsafeBufferPointer { n in
        let shift = (frame * 7) % height
        for y in 0..<height { memcpy(base + y * stride, n.baseAddress! + ((y + shift) % height) * rowBytes, rowBytes) }
      }
    }
  }
}

final class Run {
  var submits: [Int: Double] = [:]
  var firstOutput: [Int: Double] = [:]
  var lastOutput: [Int: Double] = [:]
  var outputs = 0, bytes = 0, keyframes = 0, dropped = 0, errors = 0
  var outputHeights: [Int: Int] = [:]
  var outputsPerFrame: [Int: Int] = [:]
  var errorCodes: [OSStatus: Int] = [:]
  let lock = NSLock()

  func record(index: Int, status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
    let t = nowMs()
    lock.lock()
    defer { lock.unlock() }
    if status != noErr { errors += 1; errorCodes[status, default: 0] += 1; return }
    if flags.contains(.frameDropped) || sample == nil { dropped += 1; return }
    outputs += 1
    outputsPerFrame[index, default: 0] += 1
    if firstOutput[index] == nil { firstOutput[index] = t }
    lastOutput[index] = t
    bytes += CMSampleBufferGetTotalSampleSize(sample!)
    if let format = CMSampleBufferGetFormatDescription(sample!) {
      let h = Int(CMVideoFormatDescriptionGetDimensions(format).height)
      outputHeights[h, default: 0] += 1
    }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: false) as? [[CFString: Any]]
    if attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true { keyframes += 1 }
  }
}

let vcpCallback: VTCompressionOutputCallback = { refcon, frameRefcon, status, flags, sample in
  let state = Unmanaged<Run>.fromOpaque(refcon!).takeUnretainedValue()
  state.record(index: Int(bitPattern: frameRefcon), status: status, flags: flags, sample: sample)
}

func statusOf(_ session: VTCompressionSession, _ name: String, _ value: Any) -> OSStatus {
  guard let k = key(name) ?? (name.hasPrefix("kVT") ? nil : name as CFString) else { return -1 }
  return VTSessionSetProperty(session, key: k, value: value as CFTypeRef)
}

func supportedKeys(_ session: VTCompressionSession) -> [String] {
  var dict: CFDictionary?
  VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &dict)
  return ((dict as? [String: Any])?.keys.map { $0 } ?? []).sorted()
}

func run(_ config: Config, scene: Scene, content: Content, seconds: Double, dumpKeys: Bool) -> [String: Any] {
  var result: [String: Any] = ["config": config.name, "scene": scene.rawValue, "width": content.width, "height": content.height]
  var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
  for (name, value) in config.spec {
    if let k = key(name) { spec[k] = value } else if !name.hasPrefix("kVT") { spec[name as CFString] = value } else { result["missing_\(name)"] = true }
  }
  let state = Run()
  var created: VTCompressionSession?
  var vcpSession: AnyObject?
  let createStatus: OSStatus
  if config.vcpTiles > 0 {
    spec["NumberOfTiles" as CFString] = config.vcpTiles
    var out: Unmanaged<AnyObject>?
    guard let create = vcpSymbol("VCPCompressionSessionCreate", VCPCreate.self) else { result["vcp"] = "missing"; return result }
    createStatus = create(
      kCFAllocatorDefault, Int32(content.width), Int32(content.height), kCMVideoCodecType_HEVC, spec as CFDictionary,
      nil, nil, vcpCallback, Unmanaged.passUnretained(state).toOpaque(), &out)
    vcpSession = out?.takeRetainedValue()
  } else {
    createStatus = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault, width: Int32(content.width), height: Int32(content.height),
      codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
      imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
      compressionSessionOut: &created)
  }
  result["create_status"] = createStatus
  guard createStatus == noErr, created != nil || vcpSession != nil else { return result }
  let setProperty: (CFString, CFTypeRef) -> OSStatus = { k, v in
    if let vcpSession { return vcpSymbol("VCPCompressionSessionSetProperty", VCPSetProperty.self)!(vcpSession, k, v) }
    return VTSessionSetProperty(created!, key: k, value: v)
  }
  let copyProperty: (CFString) -> CFTypeRef? = { k in
    var value: Unmanaged<CFTypeRef>?
    if let vcpSession {
      return vcpSymbol("VCPCompressionSessionCopyProperty", VCPCopyProperty.self)!(vcpSession, k, nil, &value) == noErr
        ? value?.takeRetainedValue() : nil
    }
    var plain: CFTypeRef?
    return VTSessionCopyProperty(created!, key: k, allocator: nil, valueOut: &plain) == noErr ? plain : nil
  }
  defer {
    if let vcpSession { vcpSymbol("VCPCompressionSessionInvalidate", VCPInvalidate.self)!(vcpSession) }
    if let created { VTCompressionSessionInvalidate(created) }
  }

  var statuses: [String: Int32] = [:]
  let base: [(CFString, Any)] = [
    (kVTCompressionPropertyKey_RealTime, true),
    (kVTCompressionPropertyKey_AllowFrameReordering, false),
    (kVTCompressionPropertyKey_ProfileLevel, key("kVTProfileLevel_HEVC_Main444_AutoLevel")! as Any),
    (kVTCompressionPropertyKey_ExpectedFrameRate, 60),
    (kVTCompressionPropertyKey_AverageBitRate, 45_000_000),
    (kVTCompressionPropertyKey_MaxKeyFrameInterval, 3600),
    (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
    (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB),
    (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
  ]
  for (k, v) in base { statuses[k as String] = setProperty(k, v as CFTypeRef) }
  for (name, value) in config.properties {
    let k = key(name) ?? (name.hasPrefix("kVT") ? nil : name as CFString)
    statuses[name] = k.map { setProperty($0, value as CFTypeRef) } ?? -1
  }
  if config.sections > 0, let k = key("kVTCompressionPropertyKey_NumberOfSubFrameSections") {
    statuses["kVTCompressionPropertyKey_NumberOfSubFrameSections"] = setProperty(k, config.sections as CFTypeRef)
  }
  if let created { statuses["prepare"] = VTCompressionSessionPrepareToEncodeFrames(created) }
  result["set_status"] = statuses.filter { $0.value != noErr }
  result["hardware"] = (copyProperty(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? Bool) ?? false
  if dumpKeys, let created { result["supported_keys"] = supportedKeys(created) }
  for name in ["kVTCompressionPropertyKey_Usage", "kVTCompressionPropertyKey_RequestedMaxEncoderLatency",
               "kVTCompressionPropertyKey_NumberOfSubFrameSections", "kVTCompressionPropertyKey_MaxFrameDelayCount"] {
    if let k = key(name), let value = copyProperty(k) {
      result["read_\(name.replacingOccurrences(of: "kVTCompressionPropertyKey_", with: ""))"] = "\(value)"
    }
  }

  let attributes: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey: content.width, kCVPixelBufferHeightKey: content.height,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
  ]
  var pool: CVPixelBufferPool?
  CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
  // VCP wants buffers from its own pool (its tiles need its format and size); copy BGRA into them.
  var encoderPool: CVPixelBufferPool?
  var transfer: VTPixelTransferSession?
  if let vcpSession, let p = vcpSymbol("VCPCompressionSessionGetPixelBufferPool", VCPGetPool.self)?(vcpSession),
    let attrs = CVPixelBufferPoolGetPixelBufferAttributes(p.takeUnretainedValue()) as? [String: Any]
  {
    result["vcp_pool"] = "\(attrs[kCVPixelBufferPixelFormatTypeKey as String] ?? "?") \(attrs[kCVPixelBufferWidthKey as String] ?? "?")x\(attrs[kCVPixelBufferHeightKey as String] ?? "?")"
  }
  if config.inputFormat != 0 {
    let converted: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: config.inputFormat,
      kCVPixelBufferWidthKey: content.width, kCVPixelBufferHeightKey: content.height,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
    ]
    CVPixelBufferPoolCreate(nil, nil, converted as CFDictionary, &encoderPool)
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    result["input_format"] = String(bytes: withUnsafeBytes(of: config.inputFormat.bigEndian) { Array($0) }, encoding: .ascii)
  }
  let frameCount = Int(seconds * 60)
  let warmUp = 60
  let queue = DispatchQueue(label: "probe", qos: .userInteractive)
  let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
  let done = DispatchSemaphore(value: 0)
  var frame = 0
  let sectionIDKey = key("kVTEncodeFrameOptionKey_SectionID")
  let sectionOffsetsKey = key("kVTEncodeFrameOptionKey_SectionOffsets")
  timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .nanoseconds(0))
  timer.setEventHandler {
    if frame >= frameCount { timer.cancel(); done.signal(); return }
    let index = frame
    frame += 1
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
    guard let buffer else { return }
    content.fill(buffer, scene: scene, frame: index)
    var encoderBuffer: CVPixelBuffer = buffer
    if let encoderPool, let transfer {
      var converted: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, encoderPool, &converted)
      if let converted, VTPixelTransferSessionTransferImage(transfer, from: buffer, to: converted) == noErr {
        encoderBuffer = converted
      }
    }
    let pts = CMTime(value: CMTimeValue(index), timescale: 60)
    let submitted = nowMs()
    state.lock.lock(); state.submits[index] = submitted; state.lock.unlock()
    let handler: VTCompressionOutputHandler = { status, flags, sample in
      state.record(index: index, status: status, flags: flags, sample: sample)
    }
    if let vcpSession {
      let status = vcpSymbol("VCPCompressionSessionEncodeFrame", VCPEncode.self)!(
        vcpSession, encoderBuffer, pts, CMTime(value: 1, timescale: 60), nil, UnsafeMutableRawPointer(bitPattern: index), nil)
      if status != noErr { state.lock.lock(); state.errors += 1; state.errorCodes[status, default: 0] += 1; state.lock.unlock() }
    } else if config.sections > 0, let session = created, let sectionIDKey, let sectionOffsetsKey {
      let sectionHeight = content.height / config.sections
      for section in 0..<config.sections {
        var options: [CFString: Any] = [sectionIDKey: section]
        if let offsets = config.sectionOffsets?(section, sectionHeight, content.height) { options[sectionOffsetsKey] = offsets }
        let status = VTCompressionSessionEncodeFrame(
          session, imageBuffer: buffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
          frameProperties: options as CFDictionary, infoFlagsOut: nil, outputHandler: handler)
        if status != noErr { state.lock.lock(); state.errors += 1; state.errorCodes[status, default: 0] += 1; state.lock.unlock() }
      }
    } else if let session = created {
      let status = VTCompressionSessionEncodeFrame(
        session, imageBuffer: buffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
        frameProperties: nil, infoFlagsOut: nil, outputHandler: handler)
      if status != noErr { state.lock.lock(); state.errors += 1; state.errorCodes[status, default: 0] += 1; state.lock.unlock() }
    }
  }
  timer.resume()
  done.wait()
  if let vcpSession { _ = vcpSymbol("VCPCompressionSessionCompleteFrames", VCPComplete.self)!(vcpSession, .invalid) }
  if let created { VTCompressionSessionCompleteFrames(created, untilPresentationTimeStamp: .invalid) }

  state.lock.lock()
  defer { state.lock.unlock() }
  var first: [Double] = [], last: [Double] = []
  for index in warmUp..<frameCount {
    guard let s = state.submits[index] else { continue }
    if let f = state.firstOutput[index] { first.append(f - s) }
    if let l = state.lastOutput[index] { last.append(l - s) }
  }
  func dist(_ v: [Double]) -> [String: Double] {
    if v.isEmpty { return [:] }
    return ["p50": (percentile(v, 0.5) * 100).rounded() / 100, "p95": (percentile(v, 0.95) * 100).rounded() / 100,
     "max": ((v.max() ?? .nan) * 100).rounded() / 100]
  }
  result["encode_first_ms"] = dist(first)
  result["encode_last_ms"] = dist(last)
  result["frames_out"] = first.count
  result["outputs"] = state.outputs
  result["mbps"] = (Double(state.bytes) * 8 / seconds / 1e6 * 10).rounded() / 10
  result["keyframes"] = state.keyframes
  result["dropped"] = state.dropped
  result["errors"] = state.errors
  result["error_codes"] = state.errorCodes.map { "\($0.key):\($0.value)" }.sorted()
  result["output_heights"] = state.outputHeights.map { "\($0.key):\($0.value)" }.sorted()
  var perFrame: [Int: Int] = [:]
  for index in warmUp..<frameCount { perFrame[state.outputsPerFrame[index] ?? 0, default: 0] += 1 }
  result["outputs_per_frame"] = perFrame.map { "\($0.key):\($0.value)" }.sorted()
  return result
}

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 6
let filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let lowLatency = "kVTVideoEncoderSpecification_EnableLowLatencyRateControl"
let speed = "kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality"
func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { $0 << 8 | OSType($1) } }
let usage42 = "kVTVideoEncoderSpecification_Usage"
var configs: [Config] = [
  Config(name: "product"),
  Config(name: "speed", properties: [speed: true]),
  Config(name: "lowlat", spec: [lowLatency: true]),
  Config(name: "lowlat+speed", spec: [lowLatency: true], properties: [speed: true]),
  Config(name: "required-lowlat", spec: ["kVTVideoEncoderSpecification_RequiredLowLatency": true]),
  Config(name: "maxframedelay0", properties: ["kVTCompressionPropertyKey_MaxFrameDelayCount": 0]),
]
for usage in [1, 20, 42, 43] {
  configs.append(Config(name: "spec-usage\(usage)", spec: [usage42: usage]))
}
configs.append(Config(name: "prop-usage42", properties: ["kVTCompressionPropertyKey_Usage": 42]))
configs.append(Config(name: "lowlat+spec-usage42", spec: [lowLatency: true, usage42: 42]))
for latency in [1, 16] {
  configs.append(Config(name: "maxlatency\(latency)", properties: ["kVTCompressionPropertyKey_RequestedMaxEncoderLatency": latency]))
}
configs.append(Config(name: "vt-sections4", sections: 4, sectionOffsets: { s, h, total in [s * h, h, total] }))
let apple: [String: Any] = [usage42: 42, "RealTime": true]
configs.append(Config(name: "vcp-tiles1+usage42-bgra", spec: [usage42: 42], vcpTiles: 1))
configs.append(Config(name: "vcp-tiles1+apple", spec: apple, vcpTiles: 1, inputFormat: fourCC("&8v4")))
configs.append(Config(name: "vcp-tiles4+apple", spec: apple, vcpTiles: 4, inputFormat: fourCC("&8v4")))
configs.append(Config(name: "vcp-tiles4+usage42", spec: [usage42: 42], vcpTiles: 4, inputFormat: fourCC("&8v4")))
configs.append(Config(name: "vcp-tiles2+apple", spec: apple, vcpTiles: 2, inputFormat: fourCC("&8v4")))

let sizes = [(2560, 1440), (3840, 2160)]
var dumped = false
for (width, height) in sizes {
  let content = Content(width: width, height: height)
  for config in configs where filter.isEmpty || config.name.contains(filter) {
    for scene in Scene.allCases {
      let result = run(config, scene: scene, content: content, seconds: seconds, dumpKeys: !dumped)
      dumped = true
      let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
      print(String(data: data, encoding: .utf8)!)
      fflush(stdout)
    }
  }
}
