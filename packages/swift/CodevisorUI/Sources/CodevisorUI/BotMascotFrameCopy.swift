import Metal
import MetalPerformanceShaders
import QuartzCore

struct BotMascotFrameCopy: @unchecked Sendable {
  private let source: any MTLTexture
  private let drawables: [any CAMetalDrawable]
  private let scaler: MPSImageLanczosScale

  init(source: any MTLTexture, drawables: [any CAMetalDrawable], scaler: MPSImageLanczosScale) {
    self.source = source
    self.drawables = drawables
    self.scaler = scaler
  }

  func finishing(_ gate: BotMascotFrameGate) -> @Sendable (any MTLCommandBuffer) -> Void {
    { commands in
      encode(into: commands)
      gate.leave()
    }
  }

  func resending(on queue: any MTLCommandQueue, then gate: BotMascotFrameGate) -> @Sendable () -> Void {
    { [queue = UncheckedQueue(queue)] in
      if let commands = queue.value.makeCommandBuffer() {
        encode(into: commands)
        commands.commit()
      }
      gate.leave()
    }
  }

  func abandoning(_ gate: BotMascotFrameGate) -> @Sendable (any Error) -> Void {
    { _ in gate.leave() }
  }

  private func encode(into commands: any MTLCommandBuffer) {
    for drawable in drawables {
      scaler.encode(commandBuffer: commands, sourceTexture: source, destinationTexture: drawable.texture)
      commands.present(drawable)
    }
  }
}

private struct UncheckedQueue: @unchecked Sendable {
  let value: any MTLCommandQueue

  init(_ value: any MTLCommandQueue) {
    self.value = value
  }
}
