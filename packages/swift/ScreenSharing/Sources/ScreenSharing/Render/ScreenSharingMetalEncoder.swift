import CoreVideo
import MetalKit

struct ScreenSharingMetalEncoder: @unchecked Sendable {
  struct Pipelines: @unchecked Sendable {
    let biplanar: any MTLRenderPipelineState
    let bgra: any MTLRenderPipelineState
    let biplanarHDR: any MTLRenderPipelineState
    let biplanarPQToSDR: any MTLRenderPipelineState
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
  struct Textures {
    enum Planes {
      case biplanar(y: CVMetalTexture, uv: CVMetalTexture, range: PlaneRange)
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
  struct PlaneRange: Equatable {
    let dynamicRange: ScreenSharingDynamicRange
    let fullRange: Bool

    var uniform: SIMD4<Float> {
      let (step, maximum): (Float, Float) = dynamicRange == .high ? (64.0 / 65535.0, 1023) : (1.0 / 255.0, 255)
      let black = (maximum + 1) / 16
      let half = (maximum + 1) / 2
      if fullRange { return SIMD4(0, 1 / (maximum * step), half * step, 1 / (maximum * step)) }
      let lumaSpan = black * 219 / 16
      let chromaSpan = black * 224 / 16
      return SIMD4(black * step, 1 / (lumaSpan * step), half * step, 1 / (chromaSpan * step))
    }
  }
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

  static func viewport(video: CGSize, target: CGSize) -> MTLViewport {
    let scale = min(target.width / video.width, target.height / video.height)
    return MTLViewport(
      originX: (target.width - video.width * scale) / 2, originY: (target.height - video.height * scale) / 2,
      width: video.width * scale, height: video.height * scale, znear: 0, zfar: 1)
  }

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

  func encode(_ textures: Textures, into target: Surface) -> Encoded? {
    encode(textures, into: target.pass, target: target.drawable.texture)
  }

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
