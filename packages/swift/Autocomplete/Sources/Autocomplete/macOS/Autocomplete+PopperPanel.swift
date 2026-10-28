#if canImport(AppKit)
  import AppKit
  import SwiftUI

  extension Autocomplete {
    @MainActor
    final class PopperPanel: NSPanel {
      static let nativeMenuCornerRadius: CGFloat = 12

      let host: PopperHostingView
      let shadowWindow = PopperShadowWindow()
      var onResignKey: () -> Void = {}
      var onCancel: () -> Void = {}

      init(content: AnyView) {
        host = PopperHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        super.init(
          contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless],
          backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        setAccessibilityRole(.popover)
        contentView = Self.glass(containing: host)
      }

      func attach(to parent: NSWindow) {
        parent.addChildWindow(shadowWindow, ordered: .above)
        parent.addChildWindow(self, ordered: .above)
      }

      func detach() {
        for window in [self, shadowWindow] {
          window.parent?.removeChildWindow(window)
          window.orderOut(nil)
        }
      }

      func fade(to alpha: CGFloat) {
        animator().alphaValue = alpha
        shadowWindow.animator().alphaValue = alpha
      }

      override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        shadowWindow.surround(frameRect, cornerRadius: Self.nativeMenuCornerRadius)
      }

      override var canBecomeKey: Bool { true }
      override var canBecomeMain: Bool { false }

      override func resignKey() {
        super.resignKey()
        onResignKey()
      }

      override func cancelOperation(_ sender: Any?) { onCancel() }

      private static func glass(containing host: NSView) -> NSView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = nativeMenuCornerRadius
        glass.contentView = PopperWashView(containing: host, cornerRadius: nativeMenuCornerRadius)
        return glass
      }
    }

    final class PopperWashView: NSView {
      private static let nativeMenuWash = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: 1, alpha: isDark ? 0.05 : 0.3)
      }

      init(containing host: NSView, cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
      }

      override var wantsUpdateLayer: Bool { true }

      override func updateLayer() {
        layer?.backgroundColor = Self.nativeMenuWash.cgColor
      }

      override func layout() {
        super.layout()
        subviews.first?.frame = bounds
      }
    }

    final class PopperHostingView: NSHostingView<AnyView> {
      var onSizeChange: () -> Void = {}

      override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange()
      }
    }
  }
#endif
