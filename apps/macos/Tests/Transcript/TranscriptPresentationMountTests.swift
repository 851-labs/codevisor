import AppKit
import CodevisorCore
import CodevisorUI
import Testing
@testable import TranscriptSurface

@Suite("A chat's transcript remembers whether it is mounted")
@MainActor
struct TranscriptPresentationMountTests {
  @Test("A transcript taken out before it was ready starts unmounted next time")
  func leavingBeforeReadyForgetsTheMount() {
    let surface = TranscriptPresentationSurface(controller: controller())
    let container = NativeTranscriptView.SurfaceContainerView()
    container.presentationSurface = surface
    container.addSubview(surface.ensureScrollView())
    surface.presentation.isTranscriptMounted = true

    container.releaseSurface()

    #expect(!surface.presentation.isTranscriptMounted)
  }

  @Test("A transcript held by another container keeps its mount when this one lets go")
  func lettingGoOfSomeoneElsesTranscriptKeepsTheMount() {
    let surface = TranscriptPresentationSurface(controller: controller())
    let holder = NativeTranscriptView.SurfaceContainerView()
    holder.addSubview(surface.ensureScrollView())
    let container = NativeTranscriptView.SurfaceContainerView()
    container.presentationSurface = surface
    surface.presentation.isTranscriptMounted = true

    container.releaseSurface()

    #expect(surface.presentation.isTranscriptMounted)
  }

  @Test("An evicted transcript starts unmounted and not ready next time")
  func evictionForgetsTheMount() {
    let surface = TranscriptPresentationSurface(controller: controller())
    _ = surface.ensureScrollView()
    surface.presentation.isTranscriptMounted = true
    surface.presentation.isInitialTranscriptReady = true

    surface.prepareForEviction()

    #expect(!surface.presentation.isTranscriptMounted)
    #expect(!surface.presentation.isInitialTranscriptReady)
  }

  @Test("A transcript set aside stays in its container, hidden, until it is released")
  func setAsideKeepsTheTranscriptHidden() {
    let surface = TranscriptPresentationSurface(controller: controller())
    let container = NativeTranscriptView.SurfaceContainerView()
    let scrollView = surface.ensureScrollView()
    container.presentationSurface = surface
    container.addSubview(scrollView)

    container.setSurfaceAside()

    #expect(scrollView.superview === container)
    #expect(scrollView.isHidden)
    #expect(container.presentationSurface == nil)

    container.releaseSurface()

    #expect(scrollView.superview == nil)
  }

  @Test("A transcript set aside in a window counts as detached and can be evicted")
  func setAsideTranscriptCanBeEvicted() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    let surface = TranscriptPresentationSurface(controller: controller())
    let container = NativeTranscriptView.SurfaceContainerView()
    window.contentView = container
    let scrollView = surface.ensureScrollView()
    container.presentationSurface = surface
    container.addSubview(scrollView)

    #expect(surface.isAttachedToWindow)

    container.setSurfaceAside()

    #expect(!surface.isAttachedToWindow)

    surface.prepareForEviction()

    #expect(surface.existingScrollView == nil)
    #expect(scrollView.superview == nil)
  }

  private func controller() -> SessionController {
    SessionController(
      project: .fromFolder(URL(fileURLWithPath: "/tmp/transcript-presentation-mount-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
  }
}
