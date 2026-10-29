import AppKit
import Metal
import ScreenSharingBenchScenes

final class PlayerWindow: NSWindow {
  let metalLayer = CAMetalLayer()
  var onInput: (() -> Void)?

  init(screen: NSScreen, device: any MTLDevice, readable: Bool) {
    super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    setFrame(screen.frame, display: false)
    level = .screenSaver
    isReleasedWhenClosed = false
    isOpaque = true
    hasShadow = false
    backgroundColor = .black
    configure(metalLayer, device: device, screen: screen, readable: readable)
    contentView = PlayerMetalView(metalLayer: metalLayer)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func keyDown(with event: NSEvent) {
    guard !event.isARepeat else { return }

    onInput?()
  }

  override func mouseDown(with event: NSEvent) {
    onInput?()
  }

  private func configure(_ layer: CAMetalLayer, device: any MTLDevice, screen: NSScreen, readable: Bool) {
    layer.device = device
    layer.pixelFormat = BenchSceneRenderer.pixelFormat
    layer.framebufferOnly = !readable
    layer.contentsScale = screen.backingScaleFactor
    layer.drawableSize = CGSize(
      width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
  }
}
