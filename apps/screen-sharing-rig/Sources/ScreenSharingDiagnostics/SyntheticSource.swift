#if os(macOS)
  import ScreenSharing
  import ScreenSharingWebRTC
  import CoreGraphics
  import CoreVideo
  import Foundation
  import VideoToolbox

  /// Diagnostic workload only. A bounded pool feeds a serial capture timer;
  /// each surface becomes immutable before it is handed to WebRTC.
  package final class SyntheticSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "codevisor.screen-sharing.synthetic", qos: .userInteractive)
    private let pool: CVPixelBufferPool
    private let convertedPool: CVPixelBufferPool?
    private let transfer: VTPixelTransferSession?
    private let configuration: ScreenSharingVideoConfiguration
    private let sender: ScreenSharingFrameSender
    private let metrics: ScreenSharingMetrics
    private var timer: DispatchSourceTimer?
    private var sequence = 0
    private var firstFrameNs: Int64?
    private let desktopPainter: ProbeDesktopPainter?
    private let burstNs: Int64 = 250_000_000
    private let gapNs: Int64?

    package init(
      configuration: ScreenSharingVideoConfiguration, sender: ScreenSharingFrameSender,
      metrics: ScreenSharingMetrics, pixelFormat: SyntheticPixelFormat = .bgra,
      desktopPattern: Bool = false, gapMilliseconds: Int? = nil
    ) throws {
      self.configuration = configuration
      self.sender = sender
      self.metrics = metrics
      gapNs = gapMilliseconds.map { Int64($0) * 1_000_000 }
      metrics.label(
        "syntheticCadence",
        gapMilliseconds.map { "250 ms bursts with \($0) ms gaps" } ?? "continuous at the configured rate")
      desktopPainter =
        desktopPattern
        ? try ProbeDesktopPainter.make(
          width: configuration.width, height: configuration.height, fps: configuration.framesPerSecond)
        : nil
      metrics.label("syntheticWorkload", desktopPattern ? "desktop text and motion" : "color bars and motion")
      var pool: CVPixelBufferPool?
      let attributes: [CFString: Any] = [
        kCVPixelBufferWidthKey: configuration.width,
        kCVPixelBufferHeightKey: configuration.height,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
      ]
      let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
      guard status == kCVReturnSuccess, let pool else { throw ScreenSharingError.codec("Create source pool", status) }
      self.pool = pool
      if pixelFormat == .nv12 {
        var convertedPool: CVPixelBufferPool?
        var convertedAttributes = attributes
        convertedAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let poolStatus = CVPixelBufferPoolCreate(nil, nil, convertedAttributes as CFDictionary, &convertedPool)
        guard poolStatus == kCVReturnSuccess, let convertedPool else {
          throw ScreenSharingError.codec("Create NV12 source pool", poolStatus)
        }
        var transfer: VTPixelTransferSession?
        let transferStatus = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        guard transferStatus == noErr, let transfer else {
          throw ScreenSharingError.codec("Create NV12 source transfer", transferStatus)
        }
        self.convertedPool = convertedPool
        self.transfer = transfer
      } else {
        convertedPool = nil
        transfer = nil
      }
      metrics.label("syntheticInputFormat", pixelFormat.rawValue)
      metrics.label("syntheticConversion", pixelFormat == .nv12 ? "BGRA to NV12 before WebRTC" : "none before WebRTC")
    }

    deinit { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }

    package func start() {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(
        deadline: .now(), repeating: .nanoseconds(1_000_000_000 / configuration.framesPerSecond),
        leeway: .milliseconds(1))
      timer.setEventHandler { [weak self] in self?.draw() }
      self.timer = timer
      timer.resume()
    }

    package func stop() {
      timer?.cancel()
      timer = nil
      queue.sync {}
    }

    private func draw() {
      autoreleasepool {
        let started = ScreenSharingMetrics.nowNs
        // Bursty input: a healthy desktop that changes in short bursts must not
        // trigger refreshes; the timer keeps running so cadence stays exact.
        if let gapNs {
          let origin = firstFrameNs ?? started
          if firstFrameNs == nil { firstFrameNs = started }
          if (started - origin) % (burstNs + gapNs) >= burstNs { return }
        }
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
          nil, pool,
          [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &pixel)
        guard status == kCVReturnSuccess, let pixel else { metrics.increment("syntheticPoolDrops"); return }
        CVPixelBufferLockBaseAddress(pixel, [])
        guard
          let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixel), width: configuration.width, height: configuration.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
            space: CGColorSpace(name: CGColorSpace.itur_709)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { CVPixelBufferUnlockBaseAddress(pixel, []); metrics.increment("syntheticDrawErrors"); return }
        if let desktopPainter {
          if firstFrameNs == nil { firstFrameNs = started }
          let frameCode = Int(
            Double(started - (firstFrameNs ?? started)) / 1_000_000_000 * Double(configuration.framesPerSecond))
          desktopPainter.draw(
            in: context,
            bounds: CGRect(x: 0, y: 0, width: configuration.width, height: configuration.height),
            sequence: frameCode, responses: 0)
        } else {
          let width = CGFloat(configuration.width)
          let height = CGFloat(configuration.height)
          context.setFillColor(CGColor(gray: 0.08, alpha: 1))
          context.fill(CGRect(x: 0, y: 0, width: width, height: height))
          for index in 0..<8 {
            context.setFillColor(
              CGColor(
                red: index & 1 == 0 ? 0.85 : 0.1,
                green: index & 2 == 0 ? 0.85 : 0.1, blue: index & 4 == 0 ? 0.85 : 0.1, alpha: 1))
            context.fill(CGRect(x: CGFloat(index) * width / 8, y: height / 2, width: width / 8, height: height / 2))
          }
          context.setFillColor(CGColor(gray: 0.95, alpha: 1))
          for row in 0..<16 {
            let offset = CGFloat((sequence * 5 + row * 43) % configuration.width)
            context.fill(CGRect(x: offset, y: CGFloat(row) * height / 36, width: width / 5, height: 2))
          }
          context.setFillColor(CGColor(red: 1, green: 0.35, blue: 0.1, alpha: 1))
          context.fill(CGRect(x: CGFloat(sequence * 7 % configuration.width), y: height / 8, width: 48, height: 96))
        }
        sequence += 1
        CVPixelBufferUnlockBaseAddress(pixel, [])
        metrics.observe("syntheticDraw", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
        guard let input = prepare(pixel) else { return }
        metrics.label("syntheticInputPixelFormatCode", String(CVPixelBufferGetPixelFormatType(input)))
        metrics.observe(
          "syntheticFramePreparation", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
        sender.push(ScreenSharingVideoFrame(pixelBuffer: input, timestampNs: started))
      }
    }

    private func prepare(_ pixel: CVPixelBuffer) -> CVPixelBuffer? {
      guard let convertedPool, let transfer else { return pixel }
      let started = ScreenSharingMetrics.nowNs
      var converted: CVPixelBuffer?
      let poolStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        nil, convertedPool, [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &converted)
      guard poolStatus == kCVReturnSuccess, let converted else {
        metrics.increment("syntheticPoolDrops"); return nil
      }
      CVBufferSetAttachment(
        converted, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(
        converted, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(
        converted, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
      let status = VTPixelTransferSessionTransferImage(transfer, from: pixel, to: converted)
      metrics.observe("syntheticConversion", milliseconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000)
      guard status == noErr else {
        metrics.increment("syntheticConversionErrors")
        metrics.label("syntheticConversionError", String(status))
        return nil
      }
      return converted
    }
  }
#endif
