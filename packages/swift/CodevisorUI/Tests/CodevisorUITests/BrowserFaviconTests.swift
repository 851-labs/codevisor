import CodevisorTestSupport
import Foundation
import ImageIO
import Testing
import WebKit
@testable import CodevisorUI

@MainActor
@Suite("Browser favicons")
struct BrowserFaviconTests {
  @Test func resolvesDeclaredIconsAndFallbackThroughTheMachine() throws {
    let page = try #require(URL(string: "http://localhost:3000/search?q=cat"))
    let candidates = BrowserFaviconLoader.candidates(
      [
        "/assets/icon.png", "/assets/icon.png", "https://cdn.example.com/icon.png",
        "http://127.0.0.1:3001/icon.png", "file:///private/icon.png", "javascript:alert(1)",
        "https://user:password@example.com/icon.png",
      ], page: page)
    #expect(
      candidates.map(\.absoluteString) == [
        "http://proxy.localhost:3000/assets/icon.png", "https://cdn.example.com/icon.png",
        "http://ipv4-127-0-0-1.proxy.localhost:3001/icon.png", "http://proxy.localhost:3000/favicon.ico",
      ])
  }

  @Test func refusesToCreateAnUnproxiedSession() {
    #expect(throws: URLError.self) { try BrowserFaviconLoader.session(for: .nonPersistent()) }
  }

  @Test func invalidAndOversizedIconsFallBackToADownsampledImage() async throws {
    let candidates = (0..<4).map { URL(string: "https://example.com/\($0).png")! }
    let png = try imageData(width: 256)
    var requests: [URL] = []
    let image = await BrowserFaviconLoader.load(candidates: candidates) { url in
      requests.append(url)
      if url == candidates[0] { return Data("<html>Not an icon</html>".utf8) }
      if url == candidates[1] { return Data(repeating: 0, count: 1_048_577) }
      return png
    }
    #expect(image?.width == 64)
    #expect(image?.height == 64)
    #expect(requests == Array(candidates.prefix(3)))
  }

  @Test func aPreviousPageCannotOverwriteTheCurrentIcon() async throws {
    let loader = BrowserFaviconLoader()
    let started = TestSignal()
    var pending: CheckedContinuation<CGImage?, Never>?
    let stale = loader.replace {
      await withCheckedContinuation { continuation in
        pending = continuation
        started.signal()
      }
    }
    await started.wait()
    let latestImage = try image(width: 32)
    let latest = loader.replace { latestImage }
    await latest.value
    pending?.resume(returning: try image(width: 16))
    await stale.value
    #expect(loader.image?.width == 32)
  }

  @Test func navigationClearsTheIconAndRejectsPendingDownloads() async throws {
    let loader = BrowserFaviconLoader()
    let initial = try image(width: 32)
    await loader.replace { initial }.value
    let started = TestSignal()
    var pending: CheckedContinuation<CGImage?, Never>?
    let download = loader.replace {
      await withCheckedContinuation { continuation in
        pending = continuation
        started.signal()
      }
    }
    await started.wait()
    loader.reset()
    #expect(loader.image == nil)
    pending?.resume(returning: initial)
    await download.value
    #expect(loader.image == nil)
  }

  private func image(width: Int) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
  }

  private func imageData(width: Int) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try image(width: width), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
}
