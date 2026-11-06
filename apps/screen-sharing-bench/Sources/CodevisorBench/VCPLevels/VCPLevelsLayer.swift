import AppKit
import Metal
import QuartzCore
import ScreenSharing
import ScreenSharingBench

@MainActor
struct VCPLevelsLayer {
  enum Space: String, CaseIterable {
    case sRGB = "8-bit, sRGB"
    case sRGBUnscaled = "8-bit, sRGB, contentsScale 1 with a full-size drawable"
    case untagged = "8-bit, untagged"
    case backedUntagged = "8-bit, untagged, layer-backed view"
    case display = "8-bit, the display's colour space"
    case linearP3 = "16-bit float, extended linear Display P3"
  }

  let view: NSView
  private let space: Space
  private let layer = CAMetalLayer()
  private let device: any MTLDevice
  private let encoder: ScreenSharingMetalEncoder

  init(_ space: Space, screen: NSScreen) throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw BenchUsageError(message: "Metal is unavailable")
    }

    self.device = device
    self.space = space
    let pipelines = try ScreenSharingMetalEncoder.Pipelines(device: device, shader: ScreenSharingMetalView.shader)
    encoder = try ScreenSharingMetalEncoder(device: device, commandQueue: queue, pipelines: pipelines)
    layer.device = device
    layer.isOpaque = true
    Self.configure(layer, space, screen: screen)
    if space == .backedUntagged {
      view = VCPLevelsBackedView(backing: layer)
    } else {
      view = NSView()
      view.layer = layer
      view.wantsLayer = true
    }
  }

  func draw(_ frame: ScreenSharingVideoFrame, scale: CGFloat) throws {
    layer.contentsScale = space == .sRGBUnscaled ? 1 : scale
    layer.drawableSize = CGSize(width: VCPLevelsRamp.width, height: VCPLevelsRamp.height)
    guard let drawable = layer.nextDrawable(), let textures = encoder.textures(for: frame),
      let encoded = encoder.encode(textures, into: pass(drawable.texture), target: drawable.texture)
    else { throw BenchUsageError(message: "the probe layer can't draw") }

    encoded.buffer.present(drawable)
    encoded.buffer.commit()
    encoded.buffer.waitUntilCompleted()
    withExtendedLifetime(encoded.retained) {}
  }

  private static func configure(_ layer: CAMetalLayer, _ space: Space, screen: NSScreen) {
    switch space {
    case .sRGB, .sRGBUnscaled:
      layer.pixelFormat = .bgra8Unorm
      layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    case .untagged, .backedUntagged:
      layer.pixelFormat = .bgra8Unorm
      layer.colorspace = nil
    case .display:
      layer.pixelFormat = .bgra8Unorm
      layer.colorspace = screen.colorSpace?.cgColorSpace
    case .linearP3:
      layer.pixelFormat = .rgba16Float
      layer.wantsExtendedDynamicRangeContent = true
      layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    }
  }

  private func pass(_ texture: any MTLTexture) -> MTLRenderPassDescriptor {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    return pass
  }
}
