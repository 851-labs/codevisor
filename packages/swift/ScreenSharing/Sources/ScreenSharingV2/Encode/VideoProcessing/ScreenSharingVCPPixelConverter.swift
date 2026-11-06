import Foundation
import CoreVideo
@preconcurrency import Metal
import ScreenSharing
import Synchronization
import VideoToolbox

final class ScreenSharingVCPPixelConverter: @unchecked Sendable {
  static let encodedPixelFormat = kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
  private static var colorTags: [(CFString, CFString)] {
    [
      (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB),
      (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
    ]
  }
  private struct Conversion: @unchecked Sendable {
    let capture: Int64
    let target: CVPixelBuffer
  }
  private struct TileConversion {
    let capture: Int64
    let tiles: [Int: CVPixelBuffer]
  }

  private let kernel: ScreenSharingVCPConversionKernel
  private let textures: ScreenSharingV2MetalTextures
  private let pool: CVPixelBufferPool
  private let layout: ScreenSharingV2TileLayout
  private let scalerLock = NSLock()
  private var scaler: VTPixelTransferSession?
  private let last = Mutex<Conversion?>(nil)
  private let tilesLock = NSLock()
  private var lastTiles: TileConversion?
  private let tilePools = Mutex<[Int: CVPixelBufferPool]>([:])

  init(layout: ScreenSharingV2TileLayout) throws {
    kernel = try ScreenSharingVCPConversionKernel.shared()
    textures = try ScreenSharingV2MetalTextures(device: kernel.device)
    self.layout = layout
    pool = try ScreenSharingV2PixelPool.make(
      width: layout.width, height: layout.height, pixelFormat: Self.encodedPixelFormat)
  }

  deinit {
    if let scaler { VTPixelTransferSessionInvalidate(scaler) }
  }

  func convert(_ source: CVPixelBuffer, capture: Int64) throws -> CVPixelBuffer {
    guard CVPixelBufferGetPixelFormatType(source) != Self.encodedPixelFormat else { return source }
    if let repeated = last.withLock({ $0?.capture == capture ? $0?.target : nil }) { return repeated }

    let target = try transfer(source)
    last.withLock { $0 = Conversion(capture: capture, target: target) }
    return target
  }

  func convertTiles(_ source: CVPixelBuffer, capture: Int64, tiles: [Int]) throws -> [Int: CVPixelBuffer]? {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
      CVPixelBufferGetWidth(source) == layout.width, CVPixelBufferGetHeight(source) == layout.height
    else { return nil }

    let tiles = tiles.filter(layout.tiles.contains)
    return try tilesLock.withLock {
      var converted = lastTiles?.capture == capture ? lastTiles?.tiles ?? [:] : [:]
      let missing = tiles.filter { converted[$0] == nil }
      if !missing.isEmpty {
        try convert(source, tiles: missing, into: &converted)
        lastTiles = TileConversion(capture: capture, tiles: converted)
      }
      return converted.filter { tiles.contains($0.key) }
    }
  }

  private func convert(_ source: CVPixelBuffer, tiles: [Int], into converted: inout [Int: CVPixelBuffer]) throws {
    var retained: [CVMetalTexture] = []
    let source = try textures.planes(of: source, retaining: &retained)[0]
    var regions: [ScreenSharingVCPConversionKernel.Region] = []
    for tile in tiles {
      let rows = layout.rows(of: tile)
      let target = try tileBuffer(height: rows.count)
      for (key, value) in Self.colorTags { CVBufferSetAttachment(target, key, value, .shouldPropagate) }
      regions.append(try region(writing: target, from: rows.lowerBound, retaining: &retained))
      converted[tile] = target
    }
    try kernel.run(source: source, regions: regions)
    withExtendedLifetime(retained) {}
    textures.flush()
  }

  private func region(
    writing target: CVPixelBuffer, from sourceRow: Int, retaining retained: inout [CVMetalTexture]
  ) throws -> ScreenSharingVCPConversionKernel.Region {
    let planes = try textures.planes(of: target, usage: [.shaderRead, .shaderWrite], retaining: &retained)
    return ScreenSharingVCPConversionKernel.Region(sourceRow: sourceRow, luma: planes[0], chroma: planes[1])
  }

  private func tileBuffer(height: Int) throws -> CVPixelBuffer {
    let pool = try tilePools.withLock { pools in
      if let pool = pools[height] { return pool }
      let pool = try ScreenSharingV2PixelPool.make(
        width: layout.width, height: height, pixelFormat: Self.encodedPixelFormat)
      pools[height] = pool
      return pool
    }
    return try ScreenSharingV2PixelPool.buffer(from: pool)
  }

  private func transfer(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
      throw ScreenSharingError.invalid("The VCP converter takes BGRA captures.")
    }

    let target = try ScreenSharingV2PixelPool.buffer(from: pool)
    if CVPixelBufferGetWidth(source) == layout.width && CVPixelBufferGetHeight(source) == layout.height {
      try convertExactly(source, into: target)
    } else {
      try scale(source, into: target)
    }
    for (key, value) in Self.colorTags { CVBufferSetAttachment(target, key, value, .shouldPropagate) }
    return target
  }

  private func convertExactly(_ source: CVPixelBuffer, into target: CVPixelBuffer) throws {
    var retained: [CVMetalTexture] = []
    try kernel.run(
      source: try textures.planes(of: source, retaining: &retained)[0],
      regions: [try region(writing: target, from: 0, retaining: &retained)])
    withExtendedLifetime(retained) {}
    textures.flush()
  }

  private func scale(_ source: CVPixelBuffer, into target: CVPixelBuffer) throws {
    try scalerLock.withLock {
      let session = try scaler ?? Self.scalingSession()
      scaler = session
      let status = VTPixelTransferSessionTransferImage(session, from: source, to: target)
      guard status == noErr else { throw ScreenSharingError.codec("Scale VCP input", status) }
    }
  }

  private static func scalingSession() throws -> VTPixelTransferSession {
    var session: VTPixelTransferSession?
    let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
    guard status == noErr, let session else { throw ScreenSharingError.codec("Create VCP scaler", status) }

    VTSessionSetProperty(
      session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    return session
  }
}
