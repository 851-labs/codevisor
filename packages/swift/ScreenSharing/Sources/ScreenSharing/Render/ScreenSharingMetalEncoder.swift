import CoreVideo
import MetalKit

package struct ScreenSharingMetalEncoder: @unchecked Sendable {
  package struct Pipelines: @unchecked Sendable {
    let biplanar: any MTLRenderPipelineState
    let bgra: any MTLRenderPipelineState
    let biplanarHDR: any MTLRenderPipelineState
    let biplanarPQToSDR: any MTLRenderPipelineState
    let biplanarSDRToLinear: any MTLRenderPipelineState
    let bgraSDRToLinear: any MTLRenderPipelineState

    package init(device: any MTLDevice, shader: String) throws {
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
  package struct Textures {
    enum Planes {
      case biplanar(y: CVMetalTexture, uv: CVMetalTexture, range: PlaneRange)
      case bgra(CVMetalTexture)
    }
    struct Layer {
      let planes: Planes
      let rows: Range<Int>?
      var pixelRows = 0
      var pixelColumns = 0
    }
    let frame: ScreenSharingVideoFrame
    let layers: [Layer]
    var planes: Planes { layers[0].planes }
    var dynamicRange: ScreenSharingDynamicRange {
      if case .biplanar(_, _, let range) = planes { return range.dynamicRange }
      return .standard
    }
    var retained: [CVMetalTexture] {
      layers.flatMap { layer in
        switch layer.planes {
        case .biplanar(let y, let uv, _): [y, uv]
        case .bgra(let plane): [plane]
        }
      }
    }

    init(frame: ScreenSharingVideoFrame, planes: Planes) {
      self.init(frame: frame, layers: [Layer(planes: planes, rows: nil)])
    }

    init(frame: ScreenSharingVideoFrame, layers: [Layer]) {
      self.frame = frame
      self.layers = layers
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
  package struct Encoded {
    package let buffer: any MTLCommandBuffer
    package let retained: TextureFrame
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

  package init(device: any MTLDevice, commandQueue: any MTLCommandQueue, pipelines: Pipelines) throws {
    var cache: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    guard status == kCVReturnSuccess, let cache else { throw ScreenSharingError.codec("Create texture cache", status) }
    self.commandQueue = commandQueue
    self.pipelines = pipelines
    textureCache = cache
  }

  static func viewport(video: CGSize, target: CGSize) -> MTLViewport {
    let scale = min(target.width / video.width, target.height / video.height)
    return MTLViewport(
      originX: (target.width - video.width * scale) / 2, originY: (target.height - video.height * scale) / 2,
      width: video.width * scale, height: video.height * scale, znear: 0, zfar: 1)
  }

  package func textures(for frame: ScreenSharingVideoFrame) -> Textures? {
    guard let tiles = frame.tiles else {
      return planes(of: frame.pixelBuffer).map { Textures(frame: frame, planes: $0) }
    }

    let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
    var layers: [Textures.Layer] = []
    for tile in tiles {
      guard CVPixelBufferGetPixelFormatType(tile.pixelBuffer) == format, let planes = planes(of: tile.pixelBuffer)
      else { return nil }

      layers.append(
        Textures.Layer(
          planes: planes, rows: tile.rows, pixelRows: CVPixelBufferGetHeight(tile.pixelBuffer),
          pixelColumns: CVPixelBufferGetWidth(tile.pixelBuffer)))
    }
    return Textures(frame: frame, layers: layers)
  }

  private func planes(of pixel: CVPixelBuffer) -> Textures.Planes? {
    let format = CVPixelBufferGetPixelFormatType(pixel)
    guard Self.supportedPixelFormats.contains(format) else { return nil }
    if format == kCVPixelFormatType_32BGRA {
      return texture(pixel, plane: 0, format: .bgra8Unorm).map { .bgra($0) }
    }
    let range = PlaneRange(
      dynamicRange: ScreenSharingDynamicRange(pixelFormat: format),
      fullRange: Self.fullRangePixelFormats.contains(format))
    let wide = range.dynamicRange == .high
    guard let y = texture(pixel, plane: 0, format: wide ? .r16Unorm : .r8Unorm),
      let uv = texture(pixel, plane: 1, format: wide ? .rg16Unorm : .rg8Unorm)
    else { return nil }
    return .biplanar(y: y, uv: uv, range: range)
  }

  func encode(_ textures: Textures, into target: Surface) -> Encoded? {
    encode(textures, into: target.pass, target: target.drawable.texture)
  }

  package func encode(
    _ textures: Textures, into pass: MTLRenderPassDescriptor, target targetTexture: any MTLTexture
  ) -> Encoded? {
    guard
      let buffer = commandQueue.makeCommandBuffer(),
      let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
    else { return nil }
    let video = textures.frame.size
    let targetSize = CGSize(width: targetTexture.width, height: targetTexture.height)
    let viewport = Self.viewport(video: video, target: targetSize)
    encoder.setViewport(viewport)
    let hdrTarget = targetTexture.pixelFormat == Self.highDynamicRangePixelFormat
    for (index, layer) in textures.layers.enumerated() {
      if let rows = layer.rows {
        guard let scissor = Self.scissor(rows, of: video.height, in: viewport, target: targetSize) else { continue }

        encoder.setScissorRect(scissor)
      }
      let neighbours = Self.neighbours(of: index, in: textures.layers)
      var tile = Self.tile(layer, above: neighbours.above, below: neighbours.below, in: video)
      encoder.setFragmentBytes(&tile, length: MemoryLayout<Float>.stride * tile.count, index: 1)
      guard draw(layer.planes, neighbours: neighbours, with: encoder, hdrTarget: hdrTarget) else {
        encoder.endEncoding()
        return nil
      }
    }
    encoder.endEncoding()
    return Encoded(buffer: buffer, retained: TextureFrame(frame: textures.frame, textures: textures.retained))
  }

  static func neighbours(
    of index: Int, in layers: [Textures.Layer]
  ) -> (above: Textures.Layer?, below: Textures.Layer?) {
    guard let rows = layers[index].rows else { return (nil, nil) }

    let above = layers.indices.contains(index - 1) ? layers[index - 1] : nil
    let below = layers.indices.contains(index + 1) ? layers[index + 1] : nil
    return (
      above.flatMap { $0.rows?.upperBound == rows.lowerBound ? $0 : nil },
      below.flatMap { $0.rows?.lowerBound == rows.upperBound ? $0 : nil }
    )
  }

  static func tile(
    _ layer: Textures.Layer, above: Textures.Layer?, below: Textures.Layer?, in picture: CGSize
  ) -> [Float] {
    guard let rows = layer.rows, picture.height > 0, picture.width > 0, !rows.isEmpty else {
      return [0, 1, 0, 1, 1, 0, 0, 0, 1]
    }

    let pixelRows = max(rows.count, layer.pixelRows)
    let columnScale = picture.width / CGFloat(max(Int(picture.width), layer.pixelColumns))
    return [
      1, Float(picture.height), Float(rows.lowerBound), Float(pixelRows), Float(rows.count),
      Float(above?.rows?.count ?? 0), above == nil ? 0 : 1, below == nil ? 0 : 1, Float(columnScale),
    ]
  }

  static func scissor(
    _ rows: Range<Int>, of height: CGFloat, in viewport: MTLViewport, target: CGSize
  ) -> MTLScissorRect? {
    let edge = { (row: Int) in Int((viewport.originY + CGFloat(row) / height * viewport.height).rounded()) }
    let top = max(0, edge(rows.lowerBound))
    let bottom = min(Int(target.height), edge(rows.upperBound))
    let left = max(0, Int(viewport.originX.rounded(.down)))
    let right = min(Int(target.width), Int((viewport.originX + viewport.width).rounded(.up)))
    guard bottom > top, right > left else { return nil }

    return MTLScissorRect(x: left, y: top, width: right - left, height: bottom - top)
  }

  private func draw(
    _ planes: Textures.Planes, neighbours: (above: Textures.Layer?, below: Textures.Layer?),
    with encoder: any MTLRenderCommandEncoder, hdrTarget: Bool
  ) -> Bool {
    let own = Self.metalTextures(planes)
    guard !own.isEmpty else { return false }

    for (slot, neighbour) in [(2, neighbours.above), (4, neighbours.below)] {
      let textures = neighbour.map { Self.metalTextures($0.planes) } ?? own
      for (offset, texture) in (textures.count == own.count ? textures : own).enumerated() {
        encoder.setFragmentTexture(texture, index: slot + offset)
      }
    }
    switch planes {
    case .biplanar(let y, let uv, let range):
      guard let yTexture = CVMetalTextureGetTexture(y), let uvTexture = CVMetalTextureGetTexture(uv) else {
        return false
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
      guard let planeTexture = CVMetalTextureGetTexture(plane) else { return false }

      encoder.setRenderPipelineState(hdrTarget ? pipelines.bgraSDRToLinear : pipelines.bgra)
      encoder.setFragmentTexture(planeTexture, index: 0)
    }
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    return true
  }

  private static func metalTextures(_ planes: Textures.Planes) -> [any MTLTexture] {
    switch planes {
    case .biplanar(let y, let uv, _):
      guard let y = CVMetalTextureGetTexture(y), let uv = CVMetalTextureGetTexture(uv) else { return [] }

      return [y, uv]
    case .bgra(let plane): return CVMetalTextureGetTexture(plane).map { [$0] } ?? []
    }
  }

  private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
    var texture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, textureCache, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
      CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
    return status == kCVReturnSuccess ? texture : nil
  }
}
