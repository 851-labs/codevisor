@preconcurrency import Metal
import ScreenSharing

final class ScreenSharingVCPConversionKernel: @unchecked Sendable {
  private static let built = Result { try ScreenSharingVCPConversionKernel() }
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void bgraTo444(texture2d<float, access::read> source [[texture(0)]],
                          texture2d<float, access::write> luma [[texture(1)]],
                          texture2d<float, access::write> chroma [[texture(2)]],
                          constant uint &sourceRow [[buffer(0)]],
                          uint2 position [[thread_position_in_grid]]) {
      if (position.x >= luma.get_width() || position.y >= luma.get_height()) { return; }
      float3 rgb = source.read(uint2(position.x, position.y + sourceRow)).rgb;
      float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
      float cb = (rgb.b - y) / 1.8556 + 128.0 / 255.0;
      float cr = (rgb.r - y) / 1.5748 + 128.0 / 255.0;
      luma.write(float4(y), position);
      chroma.write(float4(cb, cr, 0.0, 0.0), position);
    }
    """
  private static let threadgroup = MTLSize(width: 16, height: 16, depth: 1)

  let device: any MTLDevice
  private let queue: any MTLCommandQueue
  private let pipeline: any MTLComputePipelineState

  static func shared() throws -> ScreenSharingVCPConversionKernel {
    try built.get()
  }

  private init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw ScreenSharingError.unavailable("Metal is unavailable for the VCP converter.")
    }

    let library = try device.makeLibrary(source: Self.shader, options: nil)
    guard let function = library.makeFunction(name: "bgraTo444") else {
      throw ScreenSharingError.unavailable("No VCP conversion kernel.")
    }

    self.device = device
    self.queue = queue
    pipeline = try device.makeComputePipelineState(function: function)
  }

  struct Region {
    let sourceRow: Int
    let luma: any MTLTexture
    let chroma: any MTLTexture
  }

  func run(source: any MTLTexture, regions: [Region]) throws {
    guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else {
      throw ScreenSharingError.unavailable("No Metal command buffer for the VCP converter.")
    }

    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source, index: 0)
    for region in regions {
      var sourceRow = UInt32(region.sourceRow)
      encoder.setTexture(region.luma, index: 1)
      encoder.setTexture(region.chroma, index: 2)
      encoder.setBytes(&sourceRow, length: MemoryLayout<UInt32>.size, index: 0)
      encoder.dispatchThreads(
        MTLSize(width: region.luma.width, height: region.luma.height, depth: 1),
        threadsPerThreadgroup: Self.threadgroup)
    }
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    guard buffer.status == .completed else {
      throw ScreenSharingError.unavailable("The VCP conversion failed: \(buffer.error?.localizedDescription ?? "?")")
    }
  }
}
