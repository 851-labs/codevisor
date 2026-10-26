import CodevisorCore
import Foundation
import ImageIO
import Testing
@testable import CodevisorUI

@MainActor
@Suite("Browser favicon store")
struct BrowserFaviconStoreTests {
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("BrowserFaviconStoreTests-\(UUID().uuidString)", isDirectory: true)

  @Test func aSavedIconIsSharedAndShowsAfterRelaunchWithoutThePage() async throws {
    let server = FaviconServer()
    let png = try iconPNG(width: 64)
    let reference = try #require(
      await BrowserFaviconStore(directory: directory).save(
        png: png, page: "https://example.com/a", client: server))

    #expect(await server.icons == [reference: png])
    let relaunched = BrowserFaviconStore(directory: directory)
    #expect(relaunched.image(reference) == nil)
    let otherMachine = FaviconServer()
    await relaunched.load(reference, from: otherMachine)
    #expect(relaunched.image(reference)?.width == 64)
    #expect(await otherMachine.icons == [reference: png])
  }

  @Test func anotherDeviceDownloadsAnIconByItsHashOnce() async throws {
    let png = try iconPNG(width: 32)
    let reference = BrowserFavicon.reference(of: png)
    let server = FaviconServer(icons: [reference: png])
    let device = BrowserFaviconStore(directory: directory)

    await device.load(reference, from: server)
    #expect(device.image(reference)?.width == 32)
    let offline = BrowserFaviconStore(directory: directory)
    await offline.load(reference, from: FaviconServer())
    #expect(offline.image(reference)?.width == 32)
    #expect(await server.downloads == 1)
  }

  @Test func rejectsDownloadsThatDoNotMatchTheirHash() async throws {
    let reference = BrowserFavicon.reference(of: try iconPNG(width: 16))
    let store = BrowserFaviconStore(directory: directory)

    await store.load(reference, from: FaviconServer(icons: [reference: try iconPNG(width: 32)]))
    #expect(store.image(reference) == nil)
  }

  @Test func decodesOnlySmallIconsAndDownsamplesThem() async throws {
    #expect(await BrowserFavicon.decoding(try iconPNG(width: 128))?.image.width == 64)
    #expect(await BrowserFavicon.decoding(try iconPNG(width: 257, height: 1)) == nil)
    #expect(await BrowserFavicon.decoding(try iconPNG(width: 1, height: 4096)) == nil)
    #expect(await BrowserFavicon.encoding(try iconImage(width: 300, height: 300)) == nil)
  }

  @Test func publishesAnIconOnlyAfterTheMachineHasIt() async throws {
    let store = BrowserFaviconStore(directory: directory)
    let png = try iconPNG(width: 16)
    let offline = FaviconServer(failsUploads: true)

    #expect(await store.save(png: png, page: "https://github.com/a", client: offline) == nil)
    #expect(await offline.icons.isEmpty)
    let reference = BrowserFavicon.reference(of: png)
    #expect(await store.share(reference, with: offline) == nil)
    let online = FaviconServer()
    #expect(await store.share(reference, with: online) == reference)
    #expect(await online.icons == [reference: png])
    #expect(await BrowserFaviconDisk(directory: directory).originReferences() == ["https://github.com": reference])
  }

  @Test func sharesAKnownSiteIconWhenAPageLoads() async throws {
    let store = BrowserFaviconStore(directory: directory)
    let png = try iconPNG(width: 16)
    let reference = try #require(await store.save(png: png, page: "https://github.com/a", client: FaviconServer()))
    let machine = FaviconServer()
    let sharing = BrowserFaviconSharing(client: machine, store: store)
    var shared: [String] = []
    sharing.onShare = { reference, page in shared.append("\(page) \(reference)") }

    #expect(sharing.pageLoaded("https://other.com/") == nil)
    await sharing.pageLoaded("https://github.com/b")?.value
    #expect(shared == ["https://github.com/b \(reference)"])
    #expect(await machine.icons == [reference: png])
    let offline = BrowserFaviconSharing(client: FaviconServer(failsUploads: true), store: store)
    offline.onShare = { reference, page in shared.append("\(page) \(reference)") }
    await offline.pageLoaded("https://github.com/c")?.value
    #expect(shared.count == 1)
  }

  @Test func keepsTheIconWithinAnOriginOnly() {
    let pane = PaneDescriptorState(
      id: UUID(), kind: .browser, name: "Example", terminalKey: "",
      browserURL: "https://example.com/", browserFavicon: "example")
    func favicon(navigatingTo url: String) -> String? {
      BrowserPaneUpdate.navigated(pane, to: url, title: "Page")?.browserFavicon
    }

    #expect(favicon(navigatingTo: "https://example.com/b") == "example")
    #expect(favicon(navigatingTo: "https://github.com/c") == nil)
    #expect(BrowserPaneUpdate.favicon("example", savedFor: "https://example.com/z", on: pane) == nil)
    #expect(BrowserPaneUpdate.favicon("github", savedFor: "https://github.com/a", on: pane) == nil)
    #expect(BrowserPaneUpdate.favicon("other", savedFor: "https://example.com/z", on: pane)?.browserFavicon == "other")
  }

  private func iconImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
  }

  private func iconPNG(width: Int, height: Int? = nil) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try iconImage(width: width, height: height ?? width), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
}

private actor FaviconServer: BrowserFaviconClienting {
  private(set) var icons: [String: Data]
  private(set) var downloads = 0
  private let failsUploads: Bool

  init(icons: [String: Data] = [:], failsUploads: Bool = false) {
    self.icons = icons
    self.failsUploads = failsUploads
  }

  func browserFavicon(sha256: String) async throws -> Data? {
    downloads += 1
    return icons[sha256]
  }

  func publishBrowserFavicon(sha256: String, png: Data) async throws {
    guard !failsUploads else { throw URLError(.notConnectedToInternet) }

    icons[sha256] = png
  }
}
