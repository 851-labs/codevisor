#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import Testing
  @testable import CodevisorUI

  @Suite("Without animation on change")
  @MainActor
  struct WithoutAnimationTests {
    @Test("A new subject shows its first value without animating, and later changes animate")
    func newSubjectSnapsThenAnimates() {
      let probe = AnimationProbe()
      let host = HostedProbe(probe)
      defer { host.close() }

      probe.value = 1
      #expect(host.animatesUpdate())

      withAnimation(.linear(duration: 1)) {
        probe.subject = 1
        probe.value = 2
      }
      #expect(!host.animatesUpdate())

      probe.value = 3
      #expect(host.animatesUpdate())
    }
  }

  @MainActor
  @Observable
  private final class AnimationProbe {
    var subject = 0
    var value = 0
    @ObservationIgnored var lastAnimation: Animation?
  }

  private struct AnimationProbeView: View {
    let probe: AnimationProbe

    var body: some View {
      Color.clear
        .frame(width: CGFloat(10 + probe.value), height: 10)
        .transaction { probe.lastAnimation = $0.animation }
        .animation(.linear(duration: 1), value: probe.value)
        .withoutAnimation(onChangeOf: probe.subject)
    }
  }

  @MainActor
  private struct HostedProbe {
    let probe: AnimationProbe
    let hostingView: NSHostingView<AnimationProbeView>
    let window: NSWindow

    init(_ probe: AnimationProbe) {
      self.probe = probe
      hostingView = NSHostingView(rootView: AnimationProbeView(probe: probe))
      hostingView.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
      window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = hostingView
      hostingView.layoutSubtreeIfNeeded()
    }

    func animatesUpdate() -> Bool {
      probe.lastAnimation = nil
      hostingView.layoutSubtreeIfNeeded()
      return probe.lastAnimation != nil
    }

    func close() {
      window.contentView = nil
      window.close()
    }
  }
#endif
