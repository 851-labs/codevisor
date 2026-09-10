import Testing
@testable import CodevisorUI

@MainActor
struct TranscriptPresentationCacheTests {
  private final class Surface {
    var attached = false
    var discarded = false
  }

  @Test func returningTouchesRecencyAndEvictionProtectsAttachedSurfaces() {
    let cache = TranscriptPresentationCache<Int, Surface>(
      detachedLimit: 1,
      isAttached: { $0.attached },
      discard: { $0.discarded = true }
    )
    let first = Surface()
    let second = Surface()
    let visible = Surface()
    visible.attached = true
    cache.insert(first, for: 1)
    cache.insert(second, for: 2)
    cache.insert(visible, for: 3)
    #expect(cache.value(for: 1) === first)
    cache.trim()
    #expect(!first.discarded)
    #expect(second.discarded)
    #expect(!visible.discarded)
    #expect(cache.count == 2)
    cache.trim(discardingAllDetached: true)
    #expect(first.discarded)
    #expect(cache.value(for: 3) === visible)
    visible.attached = false
    cache.trim(discardingAllDetached: true)
    #expect(visible.discarded)
    #expect(cache.count == 0)
  }

  @Test func incomingPresentationSurvivesTrimUntilAttachment() {
    let cache = TranscriptPresentationCache<Int, Surface>(
      detachedLimit: 0, isAttached: { $0.attached }, discard: { $0.discarded = true }
    )
    let surface = Surface()
    cache.insert(surface, for: 1)
    cache.trim(excluding: 1)
    #expect(!surface.discarded)
    let replacement = Surface()
    cache.insert(replacement, for: 1)
    #expect(surface.discarded)
    #expect(cache.value(for: 1) === replacement)
    cache.remove { $0 == 1 }
    #expect(replacement.discarded)
    #expect(cache.count == 0)
  }
}
