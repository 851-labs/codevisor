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

  private func controller() -> SessionController {
    SessionController(
      project: .fromFolder(URL(fileURLWithPath: "/tmp/transcript-presentation-mount-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
  }
}
