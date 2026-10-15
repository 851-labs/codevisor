#if canImport(AppKit)
  import AppKit
  import QuartzCore
  import SwiftUI
  import Testing
  @testable import CodevisorUI

  @Suite("Shimmering text")
  @MainActor
  struct ShimmeringTextTests {
    @Test("A shimmer inserted into an existing SwiftUI host starts")
    func startsAfterDynamicInsertion() async {
      let hostingView = NSHostingView(rootView: AnyView(Text("Already mounted")))
      hostingView.frame = CGRect(x: 0, y: 0, width: 240, height: 40)
      let window = NSWindow(
        contentRect: hostingView.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      defer {
        window.contentView = nil
        window.close()
      }
      window.contentView = hostingView
      hostingView.layoutSubtreeIfNeeded()

      hostingView.rootView = AnyView(
        ShimmeringText(text: "Compacting context...")
          .frame(width: 180, height: 24, alignment: .leading)
      )
      hostingView.layoutSubtreeIfNeeded()

      #expect(containsShimmerAnimation(in: hostingView))
    }

    @Test("The compositor sweep installs and repeats")
    func installsRepeatingSweep() {
      let layer = ShimmerSweepLayer()

      layer.update(size: CGSize(width: 120, height: 18), colorScheme: .dark)

      let animation = layer.animation(forKey: ShimmerSweepLayer.animationKey) as? CABasicAnimation
      #expect(animation != nil)
      #expect(animation?.repeatCount == .infinity)
      #expect(abs(((animation?.fromValue as? NSNumber)?.doubleValue ?? 0) + 39.6) < 0.0001)
      #expect((animation?.toValue as? NSNumber)?.doubleValue == 120)
    }

    @Test("A removed sweep repairs itself on the next layout update")
    func repairsMissingSweep() {
      let layer = ShimmerSweepLayer()
      let size = CGSize(width: 120, height: 18)
      layer.update(size: size, colorScheme: .light)
      layer.removeAnimation(forKey: ShimmerSweepLayer.animationKey)

      layer.update(size: size, colorScheme: .light)

      #expect(layer.animation(forKey: ShimmerSweepLayer.animationKey) != nil)
    }

    @Test("Resizing retargets the sweep to the new bounds")
    func retargetsAfterResize() {
      let layer = ShimmerSweepLayer()
      layer.update(size: CGSize(width: 120, height: 18), colorScheme: .light)

      layer.update(size: CGSize(width: 240, height: 18), colorScheme: .light)

      let animation = layer.animation(forKey: ShimmerSweepLayer.animationKey) as? CABasicAnimation
      #expect(abs(((animation?.fromValue as? NSNumber)?.doubleValue ?? 0) + 79.2) < 0.0001)
      #expect((animation?.toValue as? NSNumber)?.doubleValue == 240)
    }

    @Test("Sweeps started at different times share one phase, so a remounted shimmer continues")
    func sharesOnePhase() {
      let first = ShimmerSweepLayer()
      first.mediaTime = { 100.3 }
      first.update(size: CGSize(width: 120, height: 18), colorScheme: .light)
      let second = ShimmerSweepLayer()
      second.mediaTime = { 100.7 }
      second.update(size: CGSize(width: 80, height: 18), colorScheme: .light)

      let begins = [first, second].compactMap { $0.animation(forKey: ShimmerSweepLayer.animationKey)?.beginTime }
      #expect(begins.count == 2)
      #expect(begins.allSatisfy { abs($0 - 99.6) < 0.0001 })
    }

    private func containsShimmerAnimation(in view: NSView) -> Bool {
      if let layer = view.layer, containsShimmerAnimation(in: layer) {
        return true
      }
      return view.subviews.contains { containsShimmerAnimation(in: $0) }
    }

    private func containsShimmerAnimation(in layer: CALayer) -> Bool {
      if layer.animation(forKey: ShimmerSweepLayer.animationKey) != nil {
        return true
      }
      return layer.sublayers?.contains { containsShimmerAnimation(in: $0) } == true
    }
  }
#endif
