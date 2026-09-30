import CoreVideo
import MetalKit

/// Pure Metal encoding of one frame into a surface — no actor, no AppKit.
/// One instance per thread (the texture cache is not shared); the command
/// queue and pipelines are shared (thread-safe / immutable per Metal).
struct ScreenSharingMetalEncoder: @unchecked Sendable {
  /// One pipeline per supported pixel layout, compiled once from the shared shader source.
  struct Pipelines: @unchecked Sendable {
    let biplanar: any MTLRenderPipelineState
    let bgra: any MTLRenderPipelineState
    /// HDR planes into the HDR target (`ScreenSharingMetalEncoder.highDynamicRangePixelFormat`), as linear light.
    let biplanarHDR: any MTLRenderPipelineState
    /// HDR planes into an 8-bit target: tone-mapped to SDR (a layer not yet switched, or a diagnostic path).
    let biplanarPQToSDR: any MTLRenderPipelineState
    /// SDR planes and BGRA into the HDR target: the frames while a layer switches back from HDR.
    let biplanarSDRToLinear: any MTLRenderPipelineState
    let bgraSDRToLinear: any MTLRenderPipelineState

    init(device: any MTLDevice, shader: String) throws {
      let library = try device.makeLibrary(source: shader, options: nil)
      func pipeline(
        fragment: String, target: MTLPixelFormat = .bgra8Unorm
      ) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = target
        return try device.makeRenderPipelineState(descriptor: descriptor)
      }
      biplanar = try pipeline(fragment: "screenFragment")
      bgra = try pipeline(fragment: "screenFragmentBGRA")
      biplanarHDR = try pipeline(
        fragment: "screenFragmentPQToLinear", target: ScreenSharingMetalEncoder.highDynamicRangePixelFormat)
      biplanarPQToSDR = try pipeline(fragment: "screenFragmentPQToSDR")
      let hdr = ScreenSharingMetalEncoder.highDynamicRangePixelFormat
      biplanarSDRToLinear = try pipeline(fragment: "screenFragmentSDRToLinear", target: hdr)
      bgraSDRToLinear = try pipeline(fragment: "screenFragmentBGRAToLinear", target: hdr)
    }
  }
  /// Validated plane textures of one frame, created before any drawable is acquired.
  struct Textures {
    enum Planes {
      /// 4:2:0 or 4:4:4 biplanar YCbCr, video or full range, 8 or 10 bits: the decoder's output.
      case biplanar(y: CVMetalTexture, uv: CVMetalTexture, range: PlaneRange)
      /// Packed 8-bit BGRA: a framebuffer backend's output, drawn without conversion.
      case bgra(CVMetalTexture)
    }
    let frame: ScreenSharingVideoFrame
    let planes: Planes
    var dynamicRange: ScreenSharingDynamicRange {
      if case .biplanar(_, _, let range) = planes { return range.dynamicRange }
      return .standard
    }
    var retained: [CVMetalTexture] {
      switch planes {
      case .biplanar(let y, let uv, _): [y, uv]
      case .bgra(let plane): [plane]
      }
    }
  }
  /// How a biplanar format's samples map to Y and CbCr: 8-bit codes, or 10-bit codes in the
  /// top of 16-bit words (CoreVideo's 10-bit biplanar layout), each video or full range.
  struct PlaneRange: Equatable {
    let dynamicRange: ScreenSharingDynamicRange
    let fullRange: Bool

    /// The shader's `ScreenRange`: yOffset, yScale, cOffset, cScale, on normalized samples.
    var uniform: SIMD4<Float> {
      // A normalized sample is code × step: 1/255 for 8 bits, 64/65535 for 10 bits in 16.
      let (step, maximum): (Float, Float) = dynamicRange == .high ? (64.0 / 65535.0, 1023) : (1.0 / 255.0, 255)
      let black = (maximum + 1) / 16  // 16 or 64: black, video range
      let half = (maximum + 1) / 2  // 128 or 512: zero chroma
      if fullRange { return SIMD4(0, 1 / (maximum * step), half * step, 1 / (maximum * step)) }
      let lumaSpan = black * 219 / 16  // 219 or 876
      let chromaSpan = black * 224 / 16  // 224 or 896
      return SIMD4(black * step, 1 / (lumaSpan * step), half * step, 1 / (chromaSpan * step))
    }
  }
  /// The drawable format for HDR frames: half floats, linear light in an extended Display P3 layer,
  /// SDR white at 1.0 and highlights above it.
  static let highDynamicRangePixelFormat = MTLPixelFormat.rgba16Float
  struct Encoded {
    let buffer: any MTLCommandBuffer
    let retained: TextureFrame
  }
  static let supportedPixelFormats: Set<OSType> = [
    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
    kCVPixelFormatType_32BGRA,
  ]
  static let fullRangePixelFormats: Set<OSType> = [
    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
    kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
  ]
  private let commandQueue: any MTLCommandQueue
  private let pipelines: Pipelines
  private let textureCache: CVMetalTextureCache

  init(device: any MTLDevice, commandQueue: any MTLCommandQueue, pipelines: Pipelines) throws {
    var cache: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    guard status == kCVReturnSuccess, let cache else { throw ScreenSharingError.codec("Create texture cache", status) }
    self.commandQueue = commandQueue
    self.pipelines = pipelines
    textureCache = cache
  }

  static func videoSize(of frame: ScreenSharingVideoFrame) -> CGSize {
    CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
  }

  /// The aspect-fit placement of one video inside a drawable: scaled to fit,
  /// centred, letterboxed on the short axis. Named so the letterbox geometry
  /// can be checked without a GPU drawable.
  static func viewport(video: CGSize, target: CGSize) -> MTLViewport {
    let scale = min(target.width / video.width, target.height / video.height)
    return MTLViewport(
      originX: (target.width - video.width * scale) / 2, originY: (target.height - video.height * scale) / 2,
      width: video.width * scale, height: video.height * scale, znear: 0, zfar: 1)
  }

  /// Pixel-format validation and plane textures; nil for an unsupported frame.
  func textures(for frame: ScreenSharingVideoFrame) -> Textures? {
    let pixel = frame.pixelBuffer
    let format = CVPixelBufferGetPixelFormatType(pixel)
    guard Self.supportedPixelFormats.contains(format) else { return nil }
    if format == kCVPixelFormatType_32BGRA {
      guard let plane = texture(pixel, plane: 0, format: .bgra8Unorm) else { return nil }
      return Textures(frame: frame, planes: .bgra(plane))
    }
    let range = PlaneRange(
      dynamicRange: ScreenSharingDynamicRange(pixelFormat: format),
      fullRange: Self.fullRangePixelFormats.contains(format))
    let wide = range.dynamicRange == .high
    guard let y = texture(pixel, plane: 0, format: wide ? .r16Unorm : .r8Unorm),
      let uv = texture(pixel, plane: 1, format: wide ? .rg16Unorm : .rg8Unorm)
    else { return nil }
    return Textures(frame: frame, planes: .biplanar(y: y, uv: uv, range: range))
  }

  /// Encodes and ends encoding; the buffer is neither presented nor committed here.
  /// The video is scaled to fit the target and centred, letterboxed on the short axis.
  func encode(_ textures: Textures, into target: Surface) -> Encoded? {
    encode(textures, into: target.pass, target: target.drawable.texture)
  }

  /// The same drawing against a plain render target. A drawable contributes
  /// only its texture here, so the rendered pixels can be checked against an
  /// ordinary off-screen texture, with no CoreAnimation layer to acquire and
  /// no window server session to depend on.
  func encode(
    _ textures: Textures, into pass: MTLRenderPassDescriptor, target targetTexture: any MTLTexture
  ) -> Encoded? {
    guard
      let buffer = commandQueue.makeCommandBuffer(),
      let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
    else { return nil }
    let pixel = textures.frame.pixelBuffer
    let video = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
    let targetSize = CGSize(width: targetTexture.width, height: targetTexture.height)
    encoder.setViewport(Self.viewport(video: video, target: targetSize))
    let hdrTarget = targetTexture.pixelFormat == Self.highDynamicRangePixelFormat
    switch textures.planes {
    case .biplanar(let y, let uv, let range):
      guard let yTexture = CVMetalTextureGetTexture(y), let uvTexture = CVMetalTextureGetTexture(uv) else {
        encoder.endEncoding()
        return nil
      }
      let pipeline: any MTLRenderPipelineState =
        switch (range.dynamicRange, hdrTarget) {
        case (.standard, false): pipelines.biplanar
        case (.standard, true): pipelines.biplanarSDRToLinear
        case (.high, true): pipelines.biplanarHDR
        case (.high, false): pipelines.biplanarPQToSDR
        }
      encoder.setRenderPipelineState(pipeline)
      encoder.setFragmentTexture(yTexture, index: 0)
      encoder.setFragmentTexture(uvTexture, index: 1)
      var uniform = range.uniform
      encoder.setFragmentBytes(&uniform, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
    case .bgra(let plane):
      guard let planeTexture = CVMetalTextureGetTexture(plane) else {
        encoder.endEncoding()
        return nil
      }
      encoder.setRenderPipelineState(hdrTarget ? pipelines.bgraSDRToLinear : pipelines.bgra)
      encoder.setFragmentTexture(planeTexture, index: 0)
    }
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    return Encoded(buffer: buffer, retained: TextureFrame(frame: textures.frame, textures: textures.retained))
  }

  private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
    var texture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, textureCache, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
      CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
    return status == kCVReturnSuccess ? texture : nil
  }
}
