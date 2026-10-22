#if canImport(AppKit)
  import AppKit
  import CodevisorTestSupport
  import Testing

  @testable import StreamMarkdown

  struct StaticTextCacheTests {
    @Test func preparedTextIsReusedWithoutPreparingAgain() async {
      let calls = TestSignal()
      let cache = StaticTextCache(byteBudget: .max) { request in
        calls.signal()
        return Self.prepared(request.makeText())
      }
      let request = Self.request(identity: 1)

      let first = await cache.prepared(request)
      let second = await cache.prepared(request)

      #expect(first != nil)
      #expect(first === second)
      #expect(cache.cached(request.key) === first)
      #expect(calls.value == 1)
    }

    @Test func concurrentRequestsShareOnePreparation() async {
      let started = TestSignal()
      let release = TestSignal()
      let cache = StaticTextCache(byteBudget: .max) { request in
        started.signal()
        await release.wait()
        return Self.prepared(request.makeText())
      }
      let request = Self.request(identity: 2)

      let first = cache.startPreparing(request)
      await started.wait()
      let second = cache.startPreparing(request)
      #expect(first == second)

      release.signal()
      let values = await (cache.prepared(request), first.value)
      #expect(values.0 === values.1)
      #expect(started.value == 1)
    }

    @Test func layoutScaleAndAppearanceProduceDistinctKeys() {
      let base = Self.request(identity: 3, width: 400, scale: 1)
      let wider = Self.request(identity: 3, width: 401, scale: 1)
      let retina = Self.request(identity: 3, width: 400, scale: 2)
      let dark = Self.request(identity: 3, width: 400, scale: 1, appearance: .darkAqua)
      let natural = StaticTextRequest(identity: 3, layout: .natural(inset: 0), scale: 1, appearance: .aqua) {
        NSAttributedString(string: "text")
      }

      let keys = [base.key, wider.key, retina.key, dark.key, natural.key]
      #expect(Set(keys).count == keys.count)
      #expect(Self.request(identity: 3, width: 400.2, scale: 1).key == base.key)
    }

    @Test func leastRecentlyUsedEntriesAreEvictedOverBudget() async {
      let entryCost = Self.prepared(NSAttributedString(string: "abcd")).byteCost
      let cache = StaticTextCache(byteBudget: entryCost * 2) { request in
        Self.prepared(request.makeText())
      }
      let first = Self.request(identity: 10)
      let second = Self.request(identity: 11)
      let third = Self.request(identity: 12)

      _ = await cache.prepared(first)
      _ = await cache.prepared(second)
      _ = cache.cached(first.key)
      _ = await cache.prepared(third)

      #expect(cache.cached(first.key) != nil)
      #expect(cache.cached(second.key) == nil)
      #expect(cache.cached(third.key) != nil)
      #expect(cache.totalCost <= entryCost * 2)
    }

    @Test func preparationRendersABitmapOnlyWithinThePixelBudget() async throws {
      let small = await PreparedStaticText.prepare(Self.request(identity: 20, width: 300))
      let image = try #require(small?.image)
      #expect(image.width == Int(((small?.size.width ?? 0) * 2).rounded(.up)))

      let lines = String(repeating: "line of static text\n", count: 4_000)
      let huge = await PreparedStaticText.prepare(
        StaticTextRequest(identity: 21, layout: .wrapping(width: 900, inset: 0), scale: 2, appearance: .aqua) {
          NSAttributedString(string: lines)
        })
      #expect(huge != nil)
      #expect(huge?.image == nil)
    }

    private static func request(
      identity: Int,
      width: CGFloat = 320,
      scale: CGFloat = 2,
      appearance: NSAppearance.Name = .aqua
    ) -> StaticTextRequest {
      StaticTextRequest(
        identity: identity, layout: .wrapping(width: width, inset: 0), scale: scale, appearance: appearance
      ) {
        NSAttributedString(string: "abcd", attributes: [.font: NSFont.systemFont(ofSize: 13)])
      }
    }

    private static func prepared(_ text: NSAttributedString) -> PreparedStaticText {
      let layout = try! PreparedNativeTextLayout(text: text, width: 320)
      return PreparedStaticText(layout: layout, inset: 0, image: nil, scale: 1)
    }
  }
#endif
