#if DEBUG
  import AppKit
  import CodevisorCore
  import SwiftUI

  @MainActor
  struct BentoCapture {
    let card: BentoCard
    let appearance: BentoAppearance
    let environment: AppEnvironment

    private static let windowHeight: CGFloat = 900
    private static let behindEveryWindowButStillCapturable = NSWindow.Level(
      rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

    func write(to file: URL) async throws {
      NSApp.appearance = NSAppearance(named: appearance.name)
      let window = makeWindow()
      defer { window.close() }
      window.orderFrontRegardless()
      window.makeKey()
      try await Task.sleep(for: card.settle)
      if case .window(_, _, let scroll) = card.presentation, scroll != .top {
        try await scrollDetail(in: window, to: scroll)
      }

      let capture = try await screenshot(of: capturedWindow(window))
      try BentoImageCrop.writePNG(try crop(capture), to: file)
    }

    private func makeWindow() -> NSWindow {
      guard case .window(let height, let title, _) = card.presentation else { return makeBorderlessWindow() }
      return makeTitledWindow(height: height, title: title)
    }

    private func scrollDetail(in window: NSWindow, to scroll: BentoCard.DetailScroll) async throws {
      let scrollViews = window.contentView.map(Self.scrollViews) ?? []
      guard let detail = scrollViews.max(by: { frame(of: $0).minX < frame(of: $1).minX }),
        let document = detail.documentView
      else { return }
      let clip = detail.contentView
      let overflow = max(0, document.frame.height - clip.bounds.height)
      let target: CGFloat
      switch scroll {
      case .top: return
      case .end: target = document.isFlipped ? overflow : 0
      case .endRevealing(let points): target = max(document.isFlipped ? overflow - points : points, 0)
      }
      clip.scroll(to: NSPoint(x: 0, y: target))
      detail.reflectScrolledClipView(clip)
      try await Task.sleep(for: .milliseconds(500))
    }

    private func frame(of view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
      let own = (view as? NSScrollView).map { [$0] } ?? []
      return own + view.subviews.flatMap(scrollViews)
    }

    private func makeTitledWindow(height: CGFloat, title: String) -> NSWindow {
      let controller = NSHostingController(rootView: card.content().environment(environment))
      controller.sceneBridgingOptions = .all
      let window = NSWindow(contentViewController: controller)
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      window.title = title
      window.isReleasedWhenClosed = false
      window.level = Self.behindEveryWindowButStillCapturable
      window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
      window.appearance = NSAppearance(named: appearance.name)
      window.setContentSize(NSSize(width: card.width, height: height))
      let visible = NSScreen.main?.visibleFrame ?? .zero
      window.setFrameOrigin(NSPoint(x: visible.minX, y: visible.maxY - window.frame.height))
      return window
    }

    private func makeBorderlessWindow() -> NSWindow {
      let origin = NSScreen.main?.visibleFrame.origin ?? .zero
      let frame = NSRect(origin: origin, size: NSSize(width: card.width, height: Self.windowHeight))
      let window = BorderlessKeyWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.level = Self.behindEveryWindowButStillCapturable
      window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = false
      window.appearance = NSAppearance(named: appearance.name)
      window.contentView = NSHostingView(
        rootView:
          presenter
          .environment(environment)
          .frame(width: card.width, height: Self.windowHeight, alignment: .top))
      return window
    }

    @ViewBuilder private var presenter: some View {
      let content = card.content().scrollContentBackground(.hidden).environment(environment)
      switch card.presentation {
      case .inline:
        content
      case .sheet:
        Color.clear.sheet(isPresented: .constant(true)) { content }
      case .window:
        content
      }
    }

    private func crop(_ capture: CGImage) throws -> CGImage {
      if case .window = card.presentation { return capture }
      guard card.presentation != .sheet else { return BentoSheetCrop(image: capture).panelWithoutScrim() ?? capture }
      return try BentoImageCrop(image: capture).cropped(toSection: card.section)
    }

    private func capturedWindow(_ window: NSWindow) -> NSWindow {
      if case .window = card.presentation { return window }
      return window.attachedSheet ?? window
    }

    private var shadowArguments: [String] {
      if case .window = card.presentation { return [] }
      return ["-o"]
    }

    private func screenshot(of window: NSWindow) async throws -> CGImage {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("bento-\(UUID().uuidString).png")
      defer { try? FileManager.default.removeItem(at: file) }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x"] + shadowArguments + ["-l", String(window.windowNumber), file.path]
      try process.run()
      while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
      guard process.terminationStatus == 0,
        let source = CGImageSourceCreateWithURL(file as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(
          source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
      else { throw BentoCaptureError.screencaptureFailed(card.name) }
      return image
    }
  }

  private final class BorderlessKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
  }

  enum BentoCaptureError: Error {
    case screencaptureFailed(String)
    case sectionNotFound(Int)
  }
#endif
